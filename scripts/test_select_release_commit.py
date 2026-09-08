"""Release resume checks against real Git history, without remote writes."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from select_release_commit import main, select_release_commit


class ReleaseCommitSelectionTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.git("init", "--quiet", "--initial-branch=main")
        (self.root / "README.md").write_text("First reviewed commit\n", encoding="utf-8")
        self.first = self.commit()
        (self.root / "README.md").write_text("Later reviewed commit\n", encoding="utf-8")
        self.latest = self.commit()
        self.git("update-ref", "refs/remotes/origin/main", self.latest)

    def git(self, *arguments):
        return subprocess.run(
            ["git", *arguments], cwd=self.root, check=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        ).stdout.decode().strip()

    def commit(self):
        self.git("add", ".")
        self.git("-c", "user.name=Release Test", "-c", "user.email=release-test@example.invalid",
                 "commit", "--quiet", "-m", "Fixture")
        return self.git("rev-parse", "HEAD")

    def test_exact_event_commit_remains_selected(self):
        self.assertEqual(select_release_commit(self.root, self.latest), self.latest)
        self.assertEqual(self.git("rev-parse", "HEAD"), self.latest)
        self.assertEqual(self.git("branch", "--show-current"), "")

    def test_previous_reviewed_commit_can_resume_after_main_advances(self):
        self.assertEqual(select_release_commit(self.root, self.first), self.first)
        self.assertEqual(self.git("rev-parse", "HEAD"), self.first)
        self.assertEqual(self.git("rev-parse", "origin/main"), self.latest)
        self.assertEqual(self.git("status", "--porcelain", "--untracked-files=all"), "")
        self.assertEqual((self.root / "README.md").read_text(), "First reviewed commit\n")

    def test_invalid_or_symbolic_requested_identity_cannot_change_checkout(self):
        for requested in ("main", "origin/main", self.first[:12], "A" * 40, "f" * 40,
                          self.first + "\n", "--detach", "", None):
            with self.subTest(requested=requested):
                with self.assertRaises(RuntimeError):
                    select_release_commit(self.root, requested)
                self.assertEqual(self.git("rev-parse", "HEAD"), self.latest)
                self.assertEqual(self.git("branch", "--show-current"), "main")

    def test_commit_outside_reviewed_main_history_is_rejected(self):
        self.git("checkout", "--quiet", "-b", "unreviewed", self.first)
        (self.root / "README.md").write_text("Unreviewed branch\n", encoding="utf-8")
        unreviewed = self.commit()
        self.git("checkout", "--quiet", "main")
        with self.assertRaisesRegex(RuntimeError, "origin/main"):
            select_release_commit(self.root, unreviewed)
        self.assertEqual(self.git("rev-parse", "HEAD"), self.latest)

    def test_dirty_tracked_staged_and_untracked_files_are_preserved(self):
        for change in ("tracked", "staged", "untracked"):
            with self.subTest(change=change):
                name = "README.md" if change != "untracked" else "untracked.txt"
                path = self.root / name
                original = path.read_bytes() if path.exists() else None
                path.write_text("Local work must not be replaced\n", encoding="utf-8")
                if change == "staged":
                    self.git("add", name)
                with self.assertRaisesRegex(RuntimeError, "clean"):
                    select_release_commit(self.root, self.first)
                self.assertEqual(path.read_text(), "Local work must not be replaced\n")
                self.assertEqual(self.git("rev-parse", "HEAD"), self.latest)
                if original is None:
                    path.unlink()
                else:
                    path.write_bytes(original)
                    self.git("add", name)

    def test_tree_object_cannot_be_used_as_a_commit(self):
        tree = self.git("rev-parse", "HEAD^{tree}")
        with self.assertRaisesRegex(RuntimeError, "commit"):
            select_release_commit(self.root, tree)
        self.assertEqual(self.git("rev-parse", "HEAD"), self.latest)

    def test_missing_reviewed_main_reference_fails_without_checkout(self):
        self.git("update-ref", "-d", "refs/remotes/origin/main")
        with self.assertRaisesRegex(RuntimeError, "origin/main"):
            select_release_commit(self.root, self.first)
        self.assertEqual(self.git("rev-parse", "HEAD"), self.latest)

    def test_cli_emits_selected_commit_for_the_publication_step(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "github-output"
            with patch("select_release_commit.ROOT", self.root), \
                    patch("sys.argv", ["select_release_commit.py", "--commit", self.first]), \
                    patch.dict(os.environ, {"GITHUB_OUTPUT": str(output)}):
                self.assertEqual(main(), 0)
            self.assertEqual(output.read_text(), f"commit={self.first}\n")
        self.assertEqual(self.git("rev-parse", "HEAD"), self.first)


if __name__ == "__main__":
    unittest.main()
