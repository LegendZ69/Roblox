"""Deterministic records of completed cloud checks, not engine-test attestations."""

import hashlib
import json
from pathlib import Path
import tempfile

INPUT_ROOTS = ("src", "tests", "scripts", "docs", ".github")
INPUT_FILES = (
    "VERSION", "default.project.json", "rokit.toml", "stylua.toml",
    "README.md", "CONTEXT.md", "CONTRIBUTING.md", "CHANGELOG.md",
)
OPTIONAL_INPUT_FILES = (".luaurc", ".styluaignore", ".stylua.toml", ".editorconfig", ".gitignore", ".gitattributes")
STAGES = (
    "luau-compile", "luau-analyze", "formatting", "luau-specs",
    "rojo-build", "place-verification", "python-unit-tests",
)
PENDING_CHECKS = (
    "Roblox Studio Script Analysis",
    "Studio multiplayer and DataStore integration playtesting",
    "Device rendering, input, physics, and performance playtesting",
    "Live Roblox experience publication",
)
REPORT_PATH = "build/cloud-validation.json"
PLACE_PATH = "build/DriftwoodIsles.rbxlx"


def fingerprint(root, relative):
    """Read one regular file without following symlinks inside the input tree."""
    path = root / relative
    if any(part.is_symlink() for part in (path, *path.parents) if part != root.parent):
        raise RuntimeError(f"Validation input must not be a symlink: {relative}")
    if not path.is_file():
        raise RuntimeError(f"Missing validation input: {relative}")
    data = path.read_bytes()
    return {"path": relative, "size_bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}


def snapshot_inputs(root):
    """Include tracked, untracked, and ignored files in all tested input trees."""
    root = Path(root).resolve()
    paths = set(INPUT_FILES)
    paths.update(name for name in OPTIONAL_INPUT_FILES if (root / name).exists() or (root / name).is_symlink())
    for folder in INPUT_ROOTS:
        directory = root / folder
        if directory.is_symlink() or not directory.is_dir():
            raise RuntimeError(f"Missing or linked validation input directory: {folder}")
        for path in directory.rglob("*"):
            relative = path.relative_to(root)
            if (folder == "scripts" and "__pycache__" in relative.parts and path.suffix == ".pyc") or (folder == "tests" and path.name.startswith(".runner-") and path.suffix == ".luau"):
                continue
            if path.is_symlink():
                raise RuntimeError(f"Validation input must not be a symlink: {relative.as_posix()}")
            if path.is_file():
                paths.add(relative.as_posix())
    return [fingerprint(root, path) for path in sorted(paths)]


def validate_report(root, report_path=None):
    """Reject stale, incomplete, or modified evidence against current inputs."""
    root = Path(root).resolve()
    path = Path(report_path) if report_path is not None else root / REPORT_PATH
    if path.is_symlink():
        raise RuntimeError("Validation report must not be a symlink")
    try:
        report = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise RuntimeError("Missing or invalid cloud validation report; run scripts/dev.py all") from error
    expected = {
        "schemaVersion": 1,
        "kind": "cloud-validation",
        "stages": [{"name": stage, "status": "passed"} for stage in STAGES],
        "inputs": snapshot_inputs(root),
        "place": fingerprint(root, PLACE_PATH),
        "pendingChecks": list(PENDING_CHECKS),
    }
    # JSON encoding preserves primitive types: True must not equal schema 1,
    # and a floating-point size must not pass as an integer byte count.
    if json.dumps(report, sort_keys=True) != json.dumps(expected, sort_keys=True):
        raise RuntimeError("Stale or incomplete cloud validation report; run scripts/dev.py all")
    return report


def collect_validation(root, stages):
    """Run every named stage; publish evidence only if all inputs remain stable."""
    root = Path(root).resolve()
    report_path = root / REPORT_PATH
    if report_path.parent.is_symlink():
        raise RuntimeError("Validation output directory must not be a symlink")
    report_path.parent.mkdir(exist_ok=True)
    # A failed attempt must never leave an earlier success looking current.
    report_path.unlink(missing_ok=True)
    stages = list(stages)
    if [name for name, _ in stages] != list(STAGES):
        raise RuntimeError("Cloud validation must run every required stage in order")
    before = snapshot_inputs(root)
    verified_place = None
    for name, check in stages:
        if name == "place-verification":
            verified_place = fingerprint(root, PLACE_PATH)
        check()
        if snapshot_inputs(root) != before:
            raise RuntimeError("Validation inputs changed during cloud checks; rerun after edits finish")
        if verified_place is not None and fingerprint(root, PLACE_PATH) != verified_place:
            raise RuntimeError("Verified place changed during cloud checks; rerun after edits finish")
    report = {
        "schemaVersion": 1,
        "kind": "cloud-validation",
        "stages": [{"name": stage, "status": "passed"} for stage in STAGES],
        "inputs": before,
        "place": verified_place,
        "pendingChecks": list(PENDING_CHECKS),
    }
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=report_path.parent, prefix=".cloud-validation-", delete=False) as handle:
        temporary = Path(handle.name)
        try:
            handle.write(json.dumps(report, indent=2, sort_keys=True) + "\n")
        except BaseException:
            temporary.unlink(missing_ok=True)
            raise
    try:
        temporary.replace(report_path)
    finally:
        temporary.unlink(missing_ok=True)
    return report
