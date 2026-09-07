"""Release transaction tests against a deterministic GitHub API boundary."""

import copy
import json
from pathlib import Path
import tempfile
import unittest
from urllib.error import HTTPError
from urllib.parse import parse_qs, quote, urlsplit

from publish_release import GitHubAPI, ReleaseError, publish, sha256


COMMIT = "1" * 40
TREE = "2" * 40
OTHER_COMMIT = "3" * 40
TAG_OBJECT = "4" * 40
REPOSITORY = "example/Roblox"
BASE = "/repos/" + REPOSITORY
VERSION = "0.1.0-alpha.1"
TAG = "v" + VERSION
NOTES = "# Driftwood Isles\n\nCloud checks passed. Studio checks pending.\n"


def package(directory, version=VERSION):
    files = {
        f"DriftwoodIsles-{version}.rbxlx": b"<roblox version=\"4\"/>\n",
        f"DriftwoodIsles-{version}.zip": b"verified deterministic bundle",
        "release-notes.md": NOTES.encode(),
    }
    manifest = {
        "schemaVersion": 1, "version": version, "tag": "v" + version,
        "git_commit": COMMIT, "git_tree": TREE,
        "assets": [{"name": name, "sha256": sha256(data), "size_bytes": len(data)}
                   for name, data in sorted(files.items())],
    }
    files["release-manifest.json"] = (json.dumps(manifest, sort_keys=True) + "\n").encode()
    files["SHA256SUMS"] = "".join(f"{sha256(data)}  {name}\n" for name, data in sorted(files.items())).encode()
    for name, data in files.items():
        (directory / name).write_bytes(data)
    return files


def asset(name, data):
    return {"name": name, "size": len(data), "digest": "sha256:" + sha256(data), "state": "uploaded"}


class ScriptedGitHub:
    """Controlled remote state, with explicit failure points and a write log."""

    def __init__(self, version=VERSION):
        self.tag = "v" + version
        self.prerelease = "-" in version.partition("+")[0]
        self.calls = []
        self.release = None
        self.assets = {}
        self.tag_sha = None
        self.annotated = False
        self.tree = TREE
        self.fail_upload = None
        self.commit_failed_upload = False
        self.upload_without_digest = False
        self.fail_tag_read = False

    @property
    def writes(self):
        return [call for call in self.calls if call[0] != "GET"]

    def seed_release(self, files, *, draft, count=None):
        self.release = {
            "id": 7, "tag_name": self.tag, "target_commitish": COMMIT,
            "draft": draft, "prerelease": self.prerelease, "body": NOTES,
        }
        self.assets = {name: asset(name, data) for name, data in list(sorted(files.items()))[:count]}
        if not draft:
            self.tag_sha = COMMIT

    def request(self, method, path, *, body=None, data=None, upload=False, allow_missing=False):
        self.calls.append((method, path, copy.deepcopy(body)))
        response = self.respond(method, path, body=body, data=data, upload=upload, allow_missing=allow_missing)
        return copy.deepcopy(response)

    def respond(self, method, path, *, body, data, upload, allow_missing):
        parsed = urlsplit(path)
        if method == "GET" and path == f"{BASE}/git/commits/{COMMIT}":
            return {"sha": COMMIT, "tree": {"sha": self.tree}}
        if method == "GET" and path == f"{BASE}/git/ref/tags/{quote(self.tag, safe='')}":
            if self.fail_tag_read:
                raise ReleaseError("GitHub GET request failed with HTTP 403")
            if self.tag_sha is None:
                assert allow_missing
                return None
            return {"object": {"type": "tag" if self.annotated else "commit",
                               "sha": TAG_OBJECT if self.annotated else self.tag_sha}}
        if method == "GET" and path == f"{BASE}/git/tags/{TAG_OBJECT}":
            return {"object": {"type": "commit", "sha": self.tag_sha}}
        if method == "GET" and path == f"{BASE}/releases?per_page=100&page=1":
            return [self.release] if self.release else []
        if method == "GET" and path == f"{BASE}/releases/7":
            assert self.release
            return self.release
        if method == "GET" and path == f"{BASE}/releases/7/assets?per_page=100&page=1":
            return list(self.assets.values())
        if method == "POST" and path == f"{BASE}/releases":
            assert self.release is None
            assert body["draft"] is True
            self.release = {"id": 7, **body}
            return self.release
        if method == "POST" and parsed.path == f"{BASE}/releases/7/assets":
            assert upload and self.release["draft"]
            name = parse_qs(parsed.query)["name"][0]
            assert name not in self.assets
            uploaded = asset(name, data)
            if self.upload_without_digest:
                uploaded.pop("digest")
            if name == self.fail_upload:
                if self.commit_failed_upload:
                    self.assets[name] = uploaded
                raise ReleaseError("Scripted upload interrupted")
            self.assets[name] = uploaded
            return uploaded
        if method == "PATCH" and path == f"{BASE}/releases/7":
            assert self.release["draft"] and body["draft"] is False
            self.release.update(body)
            self.tag_sha = COMMIT
            return self.release
        raise AssertionError(f"Unexpected request: {method} {path}")


class PublishTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.files = package(self.directory)
        self.api = ScriptedGitHub()

    def run_publish(self):
        return publish(self.directory, REPOSITORY, COMMIT, self.api)

    def test_local_corruption_prevents_all_api_requests(self):
        (self.directory / "release-notes.md").write_text("changed")
        with self.assertRaisesRegex(ReleaseError, "checksum mismatch"):
            self.run_publish()
        self.assertEqual(self.api.calls, [])

    def test_manifest_must_match_requested_commit_before_api_requests(self):
        with self.assertRaisesRegex(ReleaseError, "expected commit"):
            publish(self.directory, REPOSITORY, OTHER_COMMIT, self.api)
        self.assertEqual(self.api.calls, [])

    def test_semver_build_metadata_roundtrip_uses_encoded_names(self):
        for path in self.directory.iterdir():
            path.unlink()
        version = "1.2.3+build.4"
        files = package(self.directory, version)
        api = ScriptedGitHub(version)
        url = publish(self.directory, REPOSITORY, COMMIT, api)
        self.assertEqual(url, f"https://github.com/{REPOSITORY}/releases/tag/v1.2.3%2Bbuild.4")
        self.assertFalse(api.release["prerelease"])
        self.assertEqual(set(api.assets), set(files))
        self.assertTrue(any("%2B" in call[1] for call in api.writes))

    def test_self_consistent_package_missing_app_prevents_api_requests(self):
        name = f"DriftwoodIsles-{VERSION}.rbxlx"
        (self.directory / name).unlink()
        files = dict(self.files)
        del files[name]
        del files["SHA256SUMS"]
        manifest = json.loads(files["release-manifest.json"])
        manifest["assets"] = [entry for entry in manifest["assets"] if entry["name"] != name]
        files["release-manifest.json"] = json.dumps(manifest).encode()
        files["SHA256SUMS"] = "".join(f"{sha256(data)}  {filename}\n"
                                       for filename, data in sorted(files.items())).encode()
        for filename, data in files.items():
            (self.directory / filename).write_bytes(data)
        with self.assertRaisesRegex(ReleaseError, "missing its versioned place or ZIP"):
            self.run_publish()
        self.assertEqual(self.api.calls, [])

    def test_remote_tree_conflict_prevents_mutation(self):
        self.api.tree = OTHER_COMMIT
        with self.assertRaisesRegex(ReleaseError, "commit/tree"):
            self.run_publish()
        self.assertEqual(self.api.writes, [])

    def test_release_is_draft_until_all_exact_assets_are_uploaded(self):
        url = self.run_publish()
        self.assertEqual(url, f"https://github.com/{REPOSITORY}/releases/tag/{TAG}")
        writes = self.api.writes
        self.assertTrue(writes[0][2]["draft"])
        self.assertEqual(writes[0][2]["target_commitish"], COMMIT)
        self.assertTrue(writes[0][2]["prerelease"])
        self.assertEqual(len(writes), len(self.files) + 2)
        self.assertTrue(all(call[0] == "POST" and "/assets?name=" in call[1] for call in writes[1:-1]))
        self.assertEqual(writes[-1][0], "PATCH")
        self.assertFalse(self.api.release["draft"])
        self.assertEqual(self.api.tag_sha, COMMIT)
        for name, content in self.files.items():
            self.assertEqual(self.api.assets[name], asset(name, content))

    def test_identical_published_release_is_read_only_success(self):
        self.api.seed_release(self.files, draft=False)
        self.run_publish()
        self.assertEqual(self.api.writes, [])

    def test_conflicting_tag_or_release_never_mutates_remote(self):
        self.api.tag_sha = OTHER_COMMIT
        with self.assertRaisesRegex(ReleaseError, "tag targets another commit"):
            self.run_publish()
        self.assertEqual(self.api.writes, [])
        self.api.tag_sha = None
        self.api.seed_release(self.files, draft=True)
        self.api.release["target_commitish"] = OTHER_COMMIT
        with self.assertRaisesRegex(ReleaseError, "release targets another"):
            self.run_publish()
        self.assertEqual(self.api.writes, [])

    def test_conflicting_published_asset_is_not_replaced(self):
        self.api.seed_release(self.files, draft=False)
        self.api.assets["release-notes.md"]["digest"] = "sha256:" + "0" * 64
        with self.assertRaisesRegex(ReleaseError, "asset differs"):
            self.run_publish()
        self.assertEqual(self.api.writes, [])

    def test_incomplete_published_release_is_not_modified(self):
        self.api.seed_release(self.files, draft=False, count=1)
        with self.assertRaisesRegex(ReleaseError, "missing verified assets"):
            self.run_publish()
        self.assertEqual(self.api.writes, [])

    def test_interrupted_upload_stays_draft_and_resumes_matching_assets(self):
        self.api.fail_upload = sorted(self.files)[1]
        self.api.commit_failed_upload = True
        with self.assertRaisesRegex(ReleaseError, "upload interrupted"):
            self.run_publish()
        self.assertTrue(self.api.release["draft"])
        self.assertEqual(len(self.api.assets), 2)
        self.assertFalse(any(call[0] == "PATCH" for call in self.api.writes))
        old_assets = copy.deepcopy(self.api.assets)
        self.api.calls.clear()
        self.api.fail_upload = None
        self.run_publish()
        self.assertEqual(len(self.api.writes), len(self.files) - len(old_assets) + 1)
        for name, old_asset in old_assets.items():
            self.assertEqual(self.api.assets[name], old_asset)
        self.assertFalse(self.api.release["draft"])

    def test_resume_existing_partial_draft_without_creating_release(self):
        self.api.seed_release(self.files, draft=True, count=2)
        self.run_publish()
        self.assertEqual(len(self.api.writes), len(self.files) - 2 + 1)
        self.assertTrue(all("/assets?name=" in call[1] for call in self.api.writes[:-1]))

    def test_conflicting_partial_draft_does_not_upload_or_publish(self):
        self.api.seed_release(self.files, draft=True, count=1)
        next(iter(self.api.assets.values()))["digest"] = None
        with self.assertRaisesRegex(ReleaseError, "asset differs"):
            self.run_publish()
        self.assertEqual(self.api.writes, [])

    def test_upload_without_github_digest_never_publishes(self):
        self.api.upload_without_digest = True
        with self.assertRaisesRegex(ReleaseError, "asset differs"):
            self.run_publish()
        self.assertTrue(self.api.release["draft"])
        self.assertFalse(any(call[0] == "PATCH" for call in self.api.writes))

    def test_annotated_tag_resolves_to_exact_commit(self):
        self.api.seed_release(self.files, draft=False)
        self.api.annotated = True
        self.run_publish()
        self.assertEqual(self.api.writes, [])
        self.assertIn(("GET", f"{BASE}/git/tags/{TAG_OBJECT}", None), self.api.calls)

    def test_tag_permission_failure_does_not_assume_absence(self):
        self.api.fail_tag_read = True
        with self.assertRaisesRegex(ReleaseError, "HTTP 403"):
            self.run_publish()
        self.assertEqual(self.api.writes, [])

    def test_http_only_404_may_mean_missing_and_token_is_not_reported(self):
        class FailingOpener:
            status = 403

            def open(self, request, timeout):
                raise HTTPError(request.full_url, self.status, "denied", {}, None)

        api = GitHubAPI("private-test-token")
        opener = FailingOpener()
        api.opener = opener
        with self.assertRaisesRegex(ReleaseError, "HTTP 403") as raised:
            api.request("GET", BASE + "/git/ref/tags/test", allow_missing=True)
        self.assertNotIn("private-test-token", str(raised.exception))
        opener.status = 404
        self.assertIsNone(api.request("GET", BASE + "/git/ref/tags/test", allow_missing=True))
        with self.assertRaisesRegex(ReleaseError, "HTTP 404"):
            api.request("GET", BASE + "/releases")


if __name__ == "__main__":
    unittest.main()
