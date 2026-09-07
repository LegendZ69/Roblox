"""Release boundary checks using real temporary Git repositories and the place verifier."""

import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from xml.etree import ElementTree
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from package_release import package_release, validate_version
from verify_place import verify_place


class ReleasePackagingTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.write(".gitignore", "build/\n")
        self.write("VERSION", "0.1.0-alpha.1\n")
        self.write("scripts/toolchain.json", json.dumps({"luau": {"version": "0.737"}}))
        for name in ("README.md", "docs/validation.md", "docs/studio-validation.md", "CHANGELOG.md"):
            self.write(name, name + "\n")
        self.write("docs/releases/0.1.0-alpha.1.md", "Alpha release fixture\n")
        source = "print('fixture')\n"
        self.write("src/server/Main.server.luau", source)
        self.write("default.project.json", json.dumps({"tree": {
            "$className": "DataModel",
            "ServerScriptService": {"Main": {"$path": "src/server/Main.server.luau"}},
            "ReplicatedStorage": {"ReleaseVersion": {
                "$className": "StringValue", "$properties": {"Value": "0.1.0-alpha.1"},
            }},
        }}))
        # The fixture intentionally constructs a minimal XML place, without
        # implying Rojo or any Roblox engine tests ran in this Python suite.
        xml = ElementTree.Element("roblox", version="4")
        service = ElementTree.SubElement(xml, "Item", {"class": "ServerScriptService"})
        properties = ElementTree.SubElement(service, "Properties")
        ElementTree.SubElement(properties, "string", name="Name").text = "ServerScriptService"
        script = ElementTree.SubElement(service, "Item", {"class": "Script"})
        properties = ElementTree.SubElement(script, "Properties")
        ElementTree.SubElement(properties, "string", name="Name").text = "Main"
        ElementTree.SubElement(properties, "ProtectedString", name="Source").text = source
        storage = ElementTree.SubElement(xml, "Item", {"class": "ReplicatedStorage"})
        properties = ElementTree.SubElement(storage, "Properties")
        ElementTree.SubElement(properties, "string", name="Name").text = "ReplicatedStorage"
        release = ElementTree.SubElement(storage, "Item", {"class": "StringValue"})
        properties = ElementTree.SubElement(release, "Properties")
        ElementTree.SubElement(properties, "string", name="Name").text = "ReleaseVersion"
        ElementTree.SubElement(properties, "string", name="Value").text = "0.1.0-alpha.1"
        self.write("build/DriftwoodIsles.rbxlx", ElementTree.tostring(xml, encoding="unicode"))
        self.git("init", "--quiet")
        self.commit()

    def write(self, name, content):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")

    def git(self, *args):
        return subprocess.run(
            ["git", *args], cwd=self.root, check=True, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        ).stdout.decode().strip()

    def commit(self):
        self.git("add", ".")
        self.git("-c", "user.name=Release Test", "-c", "user.email=release-test@example.invalid",
                 "commit", "--quiet", "-m", "Fixture")

    def package(self, output="build/release"):
        return package_release(self.root, Path("VERSION"), Path(output))

    def test_deterministic_release_records_commit_checksums_and_pending_studio(self):
        manifest = self.package()
        self.package("build/another-release")
        assets = self.root / "build/release"
        self.assertEqual(manifest["git_commit"], self.git("rev-parse", "HEAD"))
        self.assertEqual(manifest["git_tree"], self.git("rev-parse", "HEAD^{tree}"))
        self.assertEqual(manifest["verification"]["studio"]["status"], "pending")
        self.assertEqual(manifest["toolVersions"], {"luau": "0.737"})
        self.assertNotIn(str(self.root), (assets / "release-manifest.json").read_text())
        self.assertEqual({path.name for path in assets.iterdir()}, {
            "DriftwoodIsles-0.1.0-alpha.1.rbxlx", "DriftwoodIsles-0.1.0-alpha.1.zip",
            "release-manifest.json", "SHA256SUMS", "release-notes.md",
        })
        for path in assets.iterdir():
            self.assertEqual(path.read_bytes(), (self.root / "build/another-release" / path.name).read_bytes())
        for line in (assets / "SHA256SUMS").read_text().splitlines():
            checksum, name = line.split("  ")
            self.assertEqual(checksum, hashlib.sha256((assets / name).read_bytes()).hexdigest())
        with zipfile.ZipFile(assets / "DriftwoodIsles-0.1.0-alpha.1.zip") as archive:
            self.assertEqual(archive.namelist(), sorted(item["name"] for item in manifest["archiveContents"]))
            for entry in archive.infolist():
                self.assertEqual(entry.date_time, (1980, 1, 1, 0, 0, 0))
                self.assertEqual(entry.external_attr >> 16, 0o100644)
                self.assertEqual(entry.compress_type, zipfile.ZIP_STORED)
            self.assertEqual(archive.read("VERSION"), b"0.1.0-alpha.1\n")
            self.assertEqual(archive.read("release-notes.md"), b"Alpha release fixture\n")
            inner_manifest = json.loads(archive.read("archive-manifest.json"))
            self.assertEqual(inner_manifest["git_commit"], manifest["git_commit"])
            for line in archive.read("SHA256SUMS").decode().splitlines():
                checksum, name = line.split("  ")
                self.assertEqual(checksum, hashlib.sha256(archive.read(name)).hexdigest())

    def test_dirty_or_untracked_sources_never_produce_release(self):
        for name in ("src/server/Main.server.luau", "src/server/Extra.luau"):
            with self.subTest(name=name):
                self.write(name, "return 'not committed'\n")
                with self.assertRaisesRegex(RuntimeError, "clean committed sources"):
                    self.package()
                self.assertFalse((self.root / "build/release").exists())
                if name.endswith("Extra.luau"):
                    (self.root / name).unlink()
                else:
                    self.git("checkout", "--", name)

    def test_committed_source_change_rejects_stale_place(self):
        self.write("src/server/Main.server.luau", "print('new build required')\n")
        self.commit()
        with self.assertRaisesRegex(RuntimeError, "Embedded source differs"):
            self.package()
        self.assertFalse((self.root / "build/release").exists())
        self.assertEqual(list((self.root / "build").glob(".release-*")), [])

    def test_ignored_mapped_source_cannot_claim_committed_provenance(self):
        project = json.loads((self.root / "default.project.json").read_text())
        project["tree"]["ServerScriptService"] = {
            "$className": "ServerScriptService", "$path": "src/server",
        }
        self.write("default.project.json", json.dumps(project))
        self.commit()
        source = "return 'ignored but shipped'\n"
        self.write("src/server/build/NotCommitted.luau", source)
        place_path = self.root / "build/DriftwoodIsles.rbxlx"
        xml = ElementTree.parse(place_path)
        service = xml.find("Item[@class='ServerScriptService']")
        folder = ElementTree.SubElement(service, "Item", {"class": "Folder"})
        properties = ElementTree.SubElement(folder, "Properties")
        ElementTree.SubElement(properties, "string", name="Name").text = "build"
        script = ElementTree.SubElement(folder, "Item", {"class": "ModuleScript"})
        properties = ElementTree.SubElement(script, "Properties")
        ElementTree.SubElement(properties, "string", name="Name").text = "NotCommitted"
        ElementTree.SubElement(properties, "ProtectedString", name="Source").text = source
        xml.write(place_path, encoding="utf-8")
        self.assertEqual(self.git("status", "--porcelain", "--untracked-files=all"), "")
        verify_place(self.root / "default.project.json", place_path)
        with self.assertRaisesRegex(RuntimeError, "Mapped production source is absent from the release commit"):
            self.package()
        self.assertFalse((self.root / "build/release").exists())

    def test_assume_unchanged_source_edit_is_rejected(self):
        name = "src/server/Main.server.luau"
        self.git("update-index", "--assume-unchanged", name)
        source = "print('hidden worktree change')\n"
        self.write(name, source)
        place_path = self.root / "build/DriftwoodIsles.rbxlx"
        xml = ElementTree.parse(place_path)
        xml.find(".//ProtectedString[@name='Source']").text = source
        xml.write(place_path, encoding="utf-8")
        self.assertEqual(self.git("status", "--porcelain"), "")
        verify_place(self.root / "default.project.json", place_path)
        with self.assertRaisesRegex(RuntimeError, "Mapped production source differs from the release commit"):
            self.package()
        self.assertFalse((self.root / "build/release").exists())

    def test_skip_worktree_project_edit_is_rejected(self):
        name = "default.project.json"
        self.git("update-index", "--skip-worktree", name)
        self.write(name, (self.root / name).read_text() + "\n")
        self.assertEqual(self.git("status", "--porcelain"), "")
        with self.assertRaisesRegex(RuntimeError, "working project mapping differs from the release commit"):
            self.package()
        self.assertFalse((self.root / "build/release").exists())

    def test_existing_output_is_preserved(self):
        self.write("build/release/sentinel", "existing release")
        with self.assertRaisesRegex(RuntimeError, "already exists"):
            self.package()
        self.assertEqual((self.root / "build/release/sentinel").read_text(), "existing release")

    def test_mismatched_embedded_version_is_rejected(self):
        self.write("VERSION", "0.1.0-alpha.2\n")
        self.commit()
        with self.assertRaisesRegex(RuntimeError, "ReleaseVersion must match"):
            self.package()
        self.assertFalse((self.root / "build/release").exists())

    def test_version_file_must_belong_to_repository(self):
        with self.assertRaisesRegex(RuntimeError, "must belong"):
            package_release(self.root, self.root.parent / "outside-version", Path("build/release"))

    def test_semver_and_filename_validation(self):
        for version in ("0.1.0-alpha.1", "1.2.3", "1.2.3-0.x-y+build.001", "1.2.3+001"):
            with self.subTest(version=version):
                self.assertEqual(validate_version(version), version)
        for version in ("v0.1.0-alpha.1", "01.2.3", "1.02.3", "1.2.03", "1.2", "1.2.3-01",
                        "1.2.3-alpha.00", "1.2.3-", "1.2.3+", "1.2.3/../bad", "1.2.3\n", "１.2.3"):
            with self.subTest(version=version):
                with self.assertRaisesRegex(RuntimeError, "safe SemVer"):
                    validate_version(version)


if __name__ == "__main__":
    unittest.main()
