"""Public validation-record behavior using isolated real filesystem inputs."""

import contextlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from validation_report import (
    INPUT_FILES, INPUT_ROOTS, OPTIONAL_INPUT_FILES, PENDING_CHECKS, PLACE_PATH, REPORT_PATH, STAGES,
    collect_validation, snapshot_inputs, validate_report,
)
from dev import test_tooling


class ValidationReportTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        for folder in INPUT_ROOTS:
            (self.root / folder).mkdir()
        for relative in INPUT_FILES:
            (self.root / relative).write_text("test input\n", encoding="utf-8")
        self.source = self.root / "src/Game.luau"
        self.source.write_text("return {}\n", encoding="utf-8")
        self.place = self.root / PLACE_PATH
        self.place.parent.mkdir()
        self.place.write_text("verified place\n", encoding="utf-8")
        self.path = self.root / REPORT_PATH
        self.ran = []

    def collect(self, overrides=None, names=STAGES):
        overrides = overrides or {}

        def stage(name):
            def run():
                self.ran.append(name)
                if name in overrides:
                    overrides[name]()
            return run

        return collect_validation(self.root, [(name, stage(name)) for name in names])

    def test_success_records_complete_inputs_stages_place_and_pending_engine_checks(self):
        report = self.collect()
        self.assertEqual(self.ran, list(STAGES))
        self.assertEqual(report, validate_report(self.root))
        self.assertEqual(report["inputs"], snapshot_inputs(self.root))
        self.assertEqual(report["pendingChecks"], list(PENDING_CHECKS))
        self.assertEqual(report["place"]["path"], PLACE_PATH)
        self.assertEqual(report["place"]["size_bytes"], len(b"verified place\n"))
        self.assertNotIn(str(self.root), self.path.read_text(encoding="utf-8"))

    def test_identical_runs_are_byte_deterministic(self):
        self.collect()
        first = self.path.read_bytes()
        self.collect()
        self.assertEqual(first, self.path.read_bytes())

    def test_python_tooling_requires_nonempty_successful_discovery(self):
        fixture = self.root / "scripts/test_example.py"
        with contextlib.redirect_stdout(io.StringIO()) as output:
            with self.assertRaises(subprocess.CalledProcessError):
                test_tooling(self.root)
            self.assertIn("No Python tooling tests discovered", output.getvalue())
            fixture.write_text(
                "import unittest\nclass Example(unittest.TestCase):\n"
                "    def test_example(self): self.assertTrue(True)\n", encoding="utf-8",
            )
            test_tooling(self.root)
            fixture.write_text(
                "import unittest\nclass Example(unittest.TestCase):\n"
                "    def test_example(self): self.fail('real failure')\n", encoding="utf-8",
            )
            with self.assertRaises(subprocess.CalledProcessError):
                test_tooling(self.root)

    def test_every_stage_failure_invalidates_previous_success(self):
        def fail():
            raise RuntimeError("check failed")

        for name in STAGES:
            with self.subTest(stage=name):
                self.collect()
                self.ran.clear()
                with self.assertRaisesRegex(RuntimeError, "check failed"):
                    self.collect({name: fail})
                self.assertFalse(self.path.exists())
                self.assertEqual(self.ran, list(STAGES[:STAGES.index(name) + 1]))

    def test_missing_duplicate_or_reordered_stages_fail_without_running(self):
        for names in (STAGES[:-1], (*STAGES, STAGES[-1]), tuple(reversed(STAGES))):
            with self.subTest(names=names):
                self.collect()
                self.ran.clear()
                with self.assertRaisesRegex(RuntimeError, "every required stage"):
                    self.collect(names=names)
                self.assertEqual(self.ran, [])
                self.assertFalse(self.path.exists())

    def test_edit_during_checks_fails_without_report(self):
        def edit():
            self.source.write_text("return {changed = true}\n", encoding="utf-8")

        with self.assertRaisesRegex(RuntimeError, "inputs changed"):
            self.collect({"luau-analyze": edit})
        self.assertFalse(self.path.exists())
        self.assertEqual(self.ran, list(STAGES[:2]))

    def test_new_and_deleted_inputs_during_checks_fail(self):
        new_file = self.root / "tests/New.spec.luau"
        for operation in (lambda: new_file.write_text("return function() end"), new_file.unlink):
            with self.subTest(operation=operation):
                with self.assertRaisesRegex(RuntimeError, "inputs changed"):
                    self.collect({"python-unit-tests": operation})
                self.assertFalse(self.path.exists())

    def test_reverting_edit_in_later_stage_cannot_hide_changed_inputs(self):
        original = self.source.read_bytes()
        with self.assertRaisesRegex(RuntimeError, "inputs changed"):
            self.collect({
                "luau-compile": lambda: self.source.write_text("changed"),
                "luau-analyze": lambda: self.source.write_bytes(original),
            })
        self.assertEqual(self.ran, ["luau-compile"])

    def test_verified_place_cannot_change_during_later_tests(self):
        for name in ("place-verification", "python-unit-tests"):
            with self.subTest(stage=name):
                self.place.write_text("original place")
                with self.assertRaisesRegex(RuntimeError, "Verified place changed"):
                    self.collect({name: lambda: self.place.write_text("different place")})
                self.assertFalse(self.path.exists())

    def test_optional_tool_configuration_is_fingerprinted_when_added_or_modified(self):
        for name in OPTIONAL_INPUT_FILES:
            with self.subTest(name=name):
                path = self.root / name
                with self.assertRaisesRegex(RuntimeError, "inputs changed"):
                    self.collect({"luau-analyze": lambda: path.write_text("new tool configuration")})
                self.assertFalse(self.path.exists())
                self.assertIn(name, {entry["path"] for entry in snapshot_inputs(self.root)})
                self.collect()
                path.write_text("changed configuration")
                with self.assertRaisesRegex(RuntimeError, "Stale or incomplete"):
                    validate_report(self.root)

    def test_missing_place_or_required_input_prevents_success(self):
        self.place.unlink()
        with self.assertRaisesRegex(RuntimeError, "Missing validation input"):
            self.collect()
        self.assertFalse(self.path.exists())
        self.place.write_text("restored")
        (self.root / "VERSION").unlink()
        with self.assertRaisesRegex(RuntimeError, "Missing validation input"):
            self.collect()
        self.assertFalse(self.path.exists())

    def test_stale_source_new_input_or_modified_place_rejects_saved_report(self):
        changes = (
            lambda: self.source.write_text("changed"),
            lambda: (self.root / "scripts/new.py").write_text("# new input"),
            lambda: self.place.write_text("different build"),
        )
        for change in changes:
            with self.subTest(change=change):
                self.collect()
                change()
                with self.assertRaisesRegex(RuntimeError, "Stale or incomplete"):
                    validate_report(self.root)

    def test_incomplete_or_tampered_report_is_rejected(self):
        report = self.collect()
        mutations = (
            lambda value: value["stages"].pop(),
            lambda value: value["inputs"].pop(),
            lambda value: value["pendingChecks"].clear(),
            lambda value: value.update(schemaVersion=2),
            lambda value: value.update(schemaVersion=True),
            lambda value: value["place"].update(size_bytes=float(value["place"]["size_bytes"])),
            lambda value: value.update(extra="unverified"),
        )
        for mutate in mutations:
            with self.subTest(mutate=mutate):
                altered = json.loads(json.dumps(report))
                mutate(altered)
                self.path.write_text(json.dumps(altered), encoding="utf-8")
                with self.assertRaisesRegex(RuntimeError, "Stale or incomplete"):
                    validate_report(self.root)

    def test_absent_or_malformed_report_has_actionable_error(self):
        for raw in (None, "not json", "null", "[]"):
            with self.subTest(raw=raw):
                if raw is not None:
                    self.path.write_text(raw)
                with self.assertRaisesRegex(RuntimeError, "run scripts/dev.py all"):
                    validate_report(self.root)

    def test_generated_caches_and_runner_do_not_change_inventory(self):
        before = snapshot_inputs(self.root)
        cache = self.root / "scripts/__pycache__"
        cache.mkdir()
        (cache / "generated.pyc").write_bytes(b"generated")
        (self.root / "tests/.runner-example.luau").write_text("transient runner")
        self.assertEqual(snapshot_inputs(self.root), before)
        # A cache-like folder cannot hide source files consumed by recursive checks.
        source_cache = self.root / "src/__pycache__"
        source_cache.mkdir()
        (source_cache / "Game.luau").write_text("return 'real source'")
        self.assertIn("src/__pycache__/Game.luau", {entry["path"] for entry in snapshot_inputs(self.root)})
        (self.root / "src/.runner-example.luau").write_text("real source")
        self.assertNotEqual(snapshot_inputs(self.root), before)

    def test_untracked_and_git_ignored_relevant_inputs_are_included(self):
        # A real Git fixture demonstrates ignore/index flags cannot hide bytes.
        subprocess.run(["git", "init", "--quiet"], cwd=self.root, check=True)
        (self.root / ".gitignore").write_text("src/ignored.luau\n")
        ignored = self.root / "src/ignored.luau"
        ignored.write_text("return 'still an input'")
        subprocess.run(["git", "check-ignore", "--quiet", "src/ignored.luau"], cwd=self.root, check=True)
        self.assertIn("src/ignored.luau", {entry["path"] for entry in snapshot_inputs(self.root)})
        subprocess.run(["git", "add", "src/Game.luau"], cwd=self.root, check=True)
        subprocess.run(["git", "update-index", "--assume-unchanged", "src/Game.luau"], cwd=self.root, check=True)
        before = snapshot_inputs(self.root)
        self.source.write_text("return 'index-hidden change'")
        subprocess.run(["git", "diff", "--quiet"], cwd=self.root, check=True)
        self.assertNotEqual(snapshot_inputs(self.root), before)

    def test_linked_inputs_and_output_directory_fail_closed(self):
        linked = self.root / "src/Linked.luau"
        linked.symlink_to(self.source)
        with self.assertRaisesRegex(RuntimeError, "symlink"):
            self.collect()
        linked.unlink()
        self.place.unlink()
        self.place.parent.rmdir()
        (self.root / "build").symlink_to(self.root / "src", target_is_directory=True)
        with self.assertRaisesRegex(RuntimeError, "output directory must not be a symlink"):
            self.collect()


if __name__ == "__main__":
    unittest.main()
