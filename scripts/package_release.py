#!/usr/bin/env python3
"""Package a clean, committed Driftwood Isles build for a versioned release.

This rechecks the place against production sources. It does not run Luau tests,
Roblox Studio, or device playtests. Run the full development pipeline first.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
from xml.etree import ElementTree
import zipfile

from verify_place import expected_instances, verify_place
from validation_report import validate_report


ROOT = Path(__file__).resolve().parents[1]
VERSION_PATTERN = re.compile(
    r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
    r"(?:-((?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)"
    r"(?:\.(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*))?"
    r"(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?",
    re.ASCII,
)
DOCUMENTS = (
    "README.md", "docs/validation.md", "docs/studio-validation.md", "docs/releasing.md",
    "docs/game-plan.md", "docs/milestones.md", "CONTEXT.md", "CONTRIBUTING.md", "docs/implementation-contract.md",
)
PENDING_STUDIO_CHECKS = (
    "Roblox Studio Script Analysis",
    "Actual server and client multiplayer playtests",
    "World rendering, collision, and physics",
    "Phone, tablet, and desktop layout and input playtests",
    "Live Roblox DataStore integration",
)


def validate_version(value):
    """Accept SemVer without a tag prefix, bounded for safe asset filenames."""
    if len(value) > 100 or VERSION_PATTERN.fullmatch(value) is None:
        raise RuntimeError("VERSION must be a safe SemVer value without a v prefix, such as 0.1.0-alpha.1")
    return value


def git(root, *arguments):
    return subprocess.run(
        ["git", *arguments], cwd=root, check=True, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    ).stdout


def clean_identity(root):
    # Untracked non-ignored files could otherwise be embedded by Rojo without
    # belonging to the recorded commit. Ignored build/tool outputs are allowed.
    if git(root, "status", "--porcelain", "--untracked-files=all"):
        raise RuntimeError("Release packaging requires clean committed sources, including untracked files")
    commit = git(root, "rev-parse", "HEAD").decode("ascii").strip()
    tree = git(root, "rev-parse", "HEAD^{tree}").decode("ascii").strip()
    return {"commit": commit, "tree": tree}


def committed_file(root, commit, relative_path):
    # Read documentation and pins from the commit itself so every archived file
    # has the same provenance as the recorded source tree.
    return git(root, "show", f"{commit}:{relative_path}")


def verify_committed_sources(root, commit, project_bytes):
    # Git status intentionally omits ignored files and can omit worktree edits
    # marked assume-unchanged or skip-worktree. Rojo still reads those files.
    project_path = root / "default.project.json"
    if project_path.read_bytes() != project_bytes:
        raise RuntimeError("The working project mapping differs from the release commit")
    for _, source, _ in expected_instances(project_path).values():
        if source is None:
            continue
        relative_path = source.relative_to(root).as_posix()
        try:
            committed_source = committed_file(root, commit, relative_path)
        except subprocess.CalledProcessError as error:
            raise RuntimeError(f"Mapped production source is absent from the release commit: {relative_path}") from error
        if source.read_bytes() != committed_source:
            raise RuntimeError(f"Mapped production source differs from the release commit: {relative_path}")


def fingerprint(name, data):
    return {"name": name, "size_bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}


def verified_cloud_report(root, commit):
    report = validate_report(root)
    # A clean Git status alone cannot detect ignored or index-hidden test edits.
    # Bind every tested input, not just the production scripts, to this commit.
    for entry in report["inputs"]:
        name = entry["path"]
        try:
            data = committed_file(root, commit, name)
        except subprocess.CalledProcessError as error:
            raise RuntimeError(f"Validation input is absent from the release commit: {name}") from error
        if len(data) != entry["size_bytes"] or hashlib.sha256(data).hexdigest() != entry["sha256"]:
            raise RuntimeError(f"Validation input differs from the release commit: {name}")
    return report


def json_bytes(value):
    return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode("utf-8")


def checksum_bytes(members):
    return "".join(
        f"{hashlib.sha256(data).hexdigest()}  {name}\n"
        for name, data in sorted(members.items())
    ).encode("ascii")


def make_archive(path, members):
    # Stored entries avoid compressor-version differences. These small text
    # assets are reproducible byte for byte across supported Python platforms.
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_STORED) as archive:
        for name, data in sorted(members.items()):
            entry = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            entry.create_system = 3
            entry.external_attr = 0o100644 << 16
            entry.compress_type = zipfile.ZIP_STORED
            archive.writestr(entry, data)


def package_release(root, version_file, output):
    root = root.resolve()
    version_file = (root / version_file).resolve()
    output = (root / output).resolve()
    if not version_file.is_relative_to(root):
        raise RuntimeError("The version file must belong to the source repository")
    if output.exists():
        raise RuntimeError("Release output already exists; use a fresh output directory to avoid stale assets")
    identity = clean_identity(root)
    relative_version = version_file.relative_to(root).as_posix()
    version_bytes = committed_file(root, identity["commit"], relative_version)
    version = validate_version(version_bytes.decode("utf-8").strip())
    project_bytes = committed_file(root, identity["commit"], "default.project.json")
    verify_committed_sources(root, identity["commit"], project_bytes)
    project = json.loads(project_bytes)
    release_value = project.get("tree", {}).get("ReplicatedStorage", {}).get("ReleaseVersion", {})
    if release_value.get("$className") != "StringValue" or release_value.get("$properties", {}).get("Value") != version:
        raise RuntimeError("The project's ReplicatedStorage.ReleaseVersion must match VERSION")
    toolchain = json.loads(committed_file(root, identity["commit"], "scripts/toolchain.json"))
    if not isinstance(toolchain, dict) or not toolchain:
        raise RuntimeError("Toolchain pins must be a nonempty object")
    tool_versions = {}
    for name, definition in sorted(toolchain.items()):
        if not isinstance(definition, dict) or not isinstance(definition.get("version"), str):
            raise RuntimeError(f"Missing tool version for {name}")
        tool_versions[name] = definition["version"]

    place_name = f"DriftwoodIsles-{version}.rbxlx"
    zip_name = f"DriftwoodIsles-{version}.zip"
    place_bytes = (root / "build/DriftwoodIsles.rbxlx").read_bytes()
    release_notes = committed_file(root, identity["commit"], f"docs/releases/{version}.md")
    if not release_notes.strip():
        raise RuntimeError("The version's committed release notes must not be empty")
    members = {place_name: place_bytes, "VERSION": version_bytes, "release-notes.md": release_notes}
    for name in DOCUMENTS:
        members[name] = committed_file(root, identity["commit"], name)
    if (root / "CHANGELOG.md").exists():
        members["CHANGELOG.md"] = committed_file(root, identity["commit"], "CHANGELOG.md")

    output.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=".release-", dir=output.parent))
    try:
        place_path = staging / place_name
        place_path.write_bytes(place_bytes)
        # Verify the exact bytes that will ship, not a separate read of the input.
        verify_place(root / "default.project.json", place_path)
        cloud_report = verified_cloud_report(root, identity["commit"])
        if cloud_report["place"]["sha256"] != hashlib.sha256(place_bytes).hexdigest():
            raise RuntimeError("The packaged place differs from the cloud validation report")
        members["cloud-validation.json"] = json_bytes(cloud_report)
        metadata = {
            "schemaVersion": 1,
            "application": "Driftwood Isles",
            "version": version,
            "tag": "v" + version,
            "git_commit": identity["commit"],
            "git_tree": identity["tree"],
            "toolVersions": tool_versions,
            "toolVersionsSource": "scripts/toolchain.json (pins; tools are not executed by packaging)",
            "verification": {
                "place": "Exact production source, instance hierarchy and configured properties passed during packaging",
                "behavioralTests": "Successful cloud stages recorded; packaging validates evidence but does not rerun tests",
                "cloudReport": "cloud-validation.json (inside setup ZIP)",
                "studio": {"status": "pending", "checks": list(PENDING_STUDIO_CHECKS)},
            },
        }
        # Inner integrity data covers extracted files; outer integrity data
        # covers the complete ZIP. Neither manifest tries to hash itself.
        members["archive-manifest.json"] = json_bytes({
            **metadata,
            "assets": [fingerprint(name, data) for name, data in sorted(members.items())],
        })
        members["SHA256SUMS"] = checksum_bytes(members)
        make_archive(staging / zip_name, members)
        artifacts = {
            place_name: place_bytes,
            zip_name: (staging / zip_name).read_bytes(),
            "release-notes.md": release_notes,
        }
        (staging / "release-notes.md").write_bytes(release_notes)
        manifest = {
            **metadata,
            "assets": [fingerprint(name, data) for name, data in sorted(artifacts.items())],
            "archiveContents": [fingerprint(name, data) for name, data in sorted(members.items())],
        }
        manifest_bytes = json_bytes(manifest)
        artifacts["release-manifest.json"] = manifest_bytes
        (staging / "release-manifest.json").write_bytes(manifest_bytes)
        (staging / "SHA256SUMS").write_bytes(checksum_bytes(artifacts))
        if clean_identity(root) != identity:
            raise RuntimeError("The source commit changed while packaging; rerun from a stable checkout")
        verify_committed_sources(root, identity["commit"], project_bytes)
        if validate_report(root) != cloud_report:
            raise RuntimeError("Cloud validation evidence changed while packaging")
        if output.exists():
            raise RuntimeError("Release output appeared while packaging; refusing to replace it")
        os.rename(staging, output)
    finally:
        if staging.exists():
            shutil.rmtree(staging)
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version-file", type=Path, default=Path("VERSION"))
    parser.add_argument("--output", type=Path, default=Path("build/release"))
    args = parser.parse_args()
    try:
        manifest = package_release(ROOT, args.version_file, args.output)
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError, ElementTree.ParseError) as error:
        print(f"Release packaging failed: {error}", file=sys.stderr)
        return 1
    print(f"Packaged Driftwood Isles {manifest['version']} from {manifest['git_commit']}")
    print(f"Release assets: {(ROOT / args.output).resolve()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
