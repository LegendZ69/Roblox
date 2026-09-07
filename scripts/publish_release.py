#!/usr/bin/env python3
"""Publish a verified package as a GitHub release, without replacing releases.

The release stays a draft until GitHub confirms every uploaded asset's SHA-256.
Authentication is read only from GH_TOKEN. Only api.github.com and
uploads.github.com are contacted; HTTP redirects are refused.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import sys
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlencode
from urllib.request import HTTPRedirectHandler, Request, build_opener


API_VERSION = "2026-03-10"
MANIFEST_NAME = "release-manifest.json"
CHECKSUM_NAME = "SHA256SUMS"
NOTES_NAME = "release-notes.md"
SHA = re.compile(r"[0-9a-f]{40}")
FILENAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._+-]*")
SEMVER = re.compile(
    r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
    r"(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?"
    r"(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?"
)


class ReleaseError(RuntimeError):
    """Package validation, API acknowledgement, or release identity failed."""


def require(condition, message):
    if not condition:
        raise ReleaseError(message)


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def read_package(directory, commit):
    """Validate all release bytes, then retain those exact bytes for upload."""
    require(isinstance(commit, str) and SHA.fullmatch(commit), "Expected a full lowercase Git commit SHA")
    directory = Path(directory)
    files = {}
    for path in directory.iterdir():
        require(FILENAME.fullmatch(path.name) and path.is_file() and not path.is_symlink(),
                f"Unexpected package entry: {path.name}")
        files[path.name] = path.read_bytes()
    require({MANIFEST_NAME, CHECKSUM_NAME, NOTES_NAME} <= files.keys(), "Package metadata is missing")
    checksums = {}
    for line in files[CHECKSUM_NAME].decode("utf-8").splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9][A-Za-z0-9._+-]*)", line)
        require(match is not None, "Malformed SHA256SUMS entry")
        digest, name = match.groups()
        require(name not in checksums, f"Duplicate checksum: {name}")
        checksums[name] = digest
    require(set(checksums) == set(files) - {CHECKSUM_NAME}, "SHA256SUMS must cover every other package file exactly")
    for name, digest in checksums.items():
        require(sha256(files[name]) == digest, f"Package checksum mismatch: {name}")
    manifest = json.loads(files[MANIFEST_NAME])
    require(isinstance(manifest, dict) and type(manifest.get("schemaVersion")) is int and manifest["schemaVersion"] == 1, "Unsupported release manifest")
    require(manifest.get("git_commit") == commit, "Manifest does not match the expected commit")
    require(isinstance(manifest.get("git_tree"), str) and SHA.fullmatch(manifest["git_tree"]), "Invalid manifest Git tree")
    version = manifest.get("version")
    match = SEMVER.fullmatch(version) if isinstance(version, str) else None
    require(match is not None, "Manifest version must be a semantic version")
    require(manifest.get("tag") == "v" + version, "Manifest tag does not match its version")
    require({f"DriftwoodIsles-{version}.rbxlx", f"DriftwoodIsles-{version}.zip"} <= files.keys(),
            "Package is missing its versioned place or ZIP")
    prerelease = match.group(4)
    require(not prerelease or all(not part.isdigit() or part == "0" or not part.startswith("0")
                                  for part in prerelease.split(".")), "Numeric prerelease identifiers cannot have leading zeros")
    entries = manifest.get("assets")
    require(isinstance(entries, list), "Manifest assets must be an array")
    asset_names = set()
    for entry in entries:
        require(isinstance(entry, dict), "Invalid manifest asset")
        name = entry.get("name")
        require(isinstance(name, str) and name in files and name not in asset_names,
                "Manifest asset is missing or duplicated")
        require(name not in {MANIFEST_NAME, CHECKSUM_NAME}, "Manifest cannot list itself or its checksum file")
        require(entry.get("sha256") == sha256(files[name]), f"Manifest digest mismatch: {name}")
        require(type(entry.get("size_bytes")) is int and entry["size_bytes"] == len(files[name]),
                f"Manifest size mismatch: {name}")
        asset_names.add(name)
    require(asset_names == set(files) - {MANIFEST_NAME, CHECKSUM_NAME}, "Manifest must cover all release payloads")
    notes = files[NOTES_NAME].decode("utf-8")
    require(bool(notes.strip()), "Release notes are empty")
    return manifest, files, notes, bool(prerelease)


class RefuseRedirects(HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, new_url):
        return None


class GitHubAPI:
    def __init__(self, token):
        require(bool(token) and "\n" not in token and "\r" not in token, "GH_TOKEN is required")
        self.token = token
        self.opener = build_opener(RefuseRedirects())

    def request(self, method, path, *, body=None, data=None, upload=False, allow_missing=False):
        require(path.startswith("/repos/") and "\\" not in path, "Invalid GitHub API path")
        require(not allow_missing or method == "GET", "Only read requests can allow a missing resource")
        require(not upload or method == "POST", "Asset upload must use POST")
        require(body is None or data is None, "Request cannot include both JSON and binary data")
        host = "uploads.github.com" if upload else "api.github.com"
        headers = {
            "Authorization": f"Bearer {self.token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": API_VERSION,
            "User-Agent": "DriftwoodIsles-release-publisher",
        }
        if body is not None:
            data = json.dumps(body).encode("utf-8")
            headers["Content-Type"] = "application/json"
        elif data is not None:
            headers["Content-Type"] = "application/octet-stream"
        request = Request(f"https://{host}{path}", data=data, headers=headers, method=method)
        try:
            with self.opener.open(request, timeout=120) as response:
                return json.load(response)
        except HTTPError as error:
            if allow_missing and error.code == 404:
                return None
            raise ReleaseError(f"GitHub {method} request failed with HTTP {error.code}") from None
        except (URLError, TimeoutError, OSError, ValueError):
            raise ReleaseError(f"GitHub {method} request failed or returned invalid JSON; rerun to inspect and resume") from None


def listed(api, path):
    results = []
    for page in range(1, 1001):
        response = api.request("GET", f"{path}?per_page=100&page={page}")
        require(isinstance(response, list), "GitHub list response is invalid")
        results.extend(response)
        if len(response) < 100:
            return results
    raise ReleaseError("GitHub pagination exceeded the supported limit")


def tag_commit(api, base, tag):
    reference = api.request("GET", f"{base}/git/ref/tags/{quote(tag, safe='')}", allow_missing=True)
    if reference is None:
        return None
    require(isinstance(reference, dict), "Invalid tag reference response")
    obj = reference.get("object")
    seen = set()
    for _ in range(10):
        require(isinstance(obj, dict) and isinstance(obj.get("sha"), str) and SHA.fullmatch(obj["sha"]),
                "Invalid tag object")
        if obj.get("type") == "commit":
            return obj["sha"]
        require(obj.get("type") == "tag" and obj["sha"] not in seen, "Tag must resolve to a commit")
        seen.add(obj["sha"])
        response = api.request("GET", f"{base}/git/tags/{obj['sha']}")
        require(isinstance(response, dict), "Invalid annotated tag response")
        obj = response.get("object")
    raise ReleaseError("Annotated tag nesting exceeded the supported limit")


def check_release(release, tag, commit, prerelease, notes):
    require(isinstance(release, dict), "Invalid release response")
    require(type(release.get("id")) is int and release["id"] > 0, "Release has an invalid identifier")
    require(release.get("tag_name") == tag and release.get("target_commitish") == commit,
            "Existing release targets another tag or commit")
    require(type(release.get("draft")) is bool and release.get("prerelease") is prerelease,
            "Existing release has conflicting publication metadata")
    if release["draft"]:
        require(release.get("body") == notes, "Existing draft has different release notes")


def check_assets(assets, files, *, complete):
    seen = set()
    for asset in assets:
        require(isinstance(asset, dict), "Invalid release asset response")
        name = asset.get("name")
        require(isinstance(name, str) and name in files and name not in seen,
                "Existing release has an unexpected or duplicate asset")
        require(asset.get("state") == "uploaded", f"Existing asset is not completely uploaded: {name}")
        require(asset.get("digest") == f"sha256:{sha256(files[name])}" and asset.get("size") == len(files[name]),
                f"Existing asset differs from verified package: {name}")
        seen.add(name)
    if complete:
        require(seen == set(files), "Published release is missing verified assets")
    return seen


def publish(directory, repository, commit, api):
    manifest, files, notes, prerelease = read_package(directory, commit)
    require(isinstance(repository, str) and re.fullmatch(r"[A-Za-z0-9_-]+/[A-Za-z0-9_.-]+", repository)
            and repository.split("/")[1] not in {".", ".."}, "Repository must have owner/name format")
    base = f"/repos/{repository}"
    tag = "v" + manifest["version"]
    remote_commit = api.request("GET", f"{base}/git/commits/{commit}")
    require(isinstance(remote_commit, dict) and remote_commit.get("sha") == commit
            and isinstance(remote_commit.get("tree"), dict)
            and remote_commit["tree"].get("sha") == manifest["git_tree"],
            "GitHub commit/tree does not match the verified package")
    existing_tag = tag_commit(api, base, tag)
    require(existing_tag in (None, commit), "Existing version tag targets another commit")
    matches = [release for release in listed(api, f"{base}/releases")
               if isinstance(release, dict) and release.get("tag_name") == tag]
    require(len(matches) <= 1, "Multiple releases use this version tag")
    release = matches[0] if matches else None
    if release is not None:
        check_release(release, tag, commit, prerelease, notes)
        assets = listed(api, f"{base}/releases/{release['id']}/assets")
        uploaded = check_assets(assets, files, complete=not release["draft"])
        if not release["draft"]:
            require(existing_tag == commit, "Published release tag is missing")
            return f"https://github.com/{repository}/releases/tag/{quote(tag, safe='')}"
    else:
        # Existing tags are never moved. A matching unassociated tag can gain a release.
        release = api.request("POST", f"{base}/releases", body={
            "tag_name": tag, "target_commitish": commit, "name": f"Driftwood Isles {tag}",
            "body": notes, "draft": True, "prerelease": prerelease,
            "generate_release_notes": False, "make_latest": "false",
        })
        check_release(release, tag, commit, prerelease, notes)
        require(release["draft"], "GitHub did not create the release as a draft")
        uploaded = set()
    release_path = f"{base}/releases/{release['id']}"
    for name in sorted(files.keys() - uploaded):
        asset = api.request("POST", f"{release_path}/assets?{urlencode({'name': name})}",
                            data=files[name], upload=True)
        check_assets([asset], {name: files[name]}, complete=True)
    # Re-read server state immediately before making the release visible.
    release = api.request("GET", release_path)
    check_release(release, tag, commit, prerelease, notes)
    check_assets(listed(api, f"{release_path}/assets"), files, complete=True)
    require(tag_commit(api, base, tag) in (None, commit), "Version tag changed before publication")
    if release["draft"]:
        release = api.request("PATCH", release_path, body={
            "draft": False, "make_latest": "false" if prerelease else "true",
        })
        check_release(release, tag, commit, prerelease, notes)
        require(not release["draft"], "GitHub did not confirm publication")
    require(tag_commit(api, base, tag) == commit, "Published version tag does not match the package commit")
    return f"https://github.com/{repository}/releases/tag/{quote(tag, safe='')}"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, default=Path("build/release"))
    parser.add_argument("--repository", required=True)
    parser.add_argument("--commit", required=True)
    args = parser.parse_args()
    try:
        url = publish(args.directory, args.repository, args.commit, GitHubAPI(os.environ.get("GH_TOKEN", "")))
    except (ReleaseError, OSError, ValueError) as error:
        print(f"Release publication failed: {error}", file=sys.stderr)
        return 1
    print(f"Verified release: {url}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
