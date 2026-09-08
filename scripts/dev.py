#!/usr/bin/env python3
"""Driftwood Isles development commands, using the pinned tools from bootstrap_tools.py."""

import argparse
import json
from pathlib import Path
import platform
import subprocess
import sys
import tempfile

from bootstrap_tools import ROOT, default_tools_dir
from verify_place import verify_place


def executable(directory, name):
    tool = directory / (name + (".exe" if platform.system() == "Windows" else ""))
    if not tool.is_file():
        raise RuntimeError(f"Missing {tool}. Run python3 scripts/bootstrap_tools.py --destination {directory}")
    return str(tool)


def run(command, **kwargs):
    subprocess.run(command, cwd=ROOT, check=True, **kwargs)


def source_files():
    return sorted(path for folder in (ROOT / "src", ROOT / "tests") for path in folder.rglob("*") if path.suffix in (".lua", ".luau") and not path.name.startswith(".runner-"))


def check(tools_dir):
    files = source_files()
    if not files:
        raise RuntimeError("No Luau source files were found")
    compiler = executable(tools_dir, "luau-compile")
    failures = []
    for file in files:
        result = subprocess.run([compiler, "--null", str(file)], cwd=ROOT, stdout=subprocess.DEVNULL)
        if result.returncode:
            failures.append(str(file.relative_to(ROOT)))
    if failures:
        raise RuntimeError("Luau compilation failed: " + ", ".join(failures))
    print(f"Luau syntax: {len(files)} files compiled successfully", flush=True)
    # These modules have no engine-instance dependencies and can be strictly
    # analyzed by the official standalone CLI. Roblox integration is checked
    # by Studio Script Analysis, never by suppressing its unknown engine types.
    core_files = [
        ROOT / "src/shared/Config.luau",
        ROOT / "src/shared/ClientPolicy.luau",
        ROOT / "src/server/Island.luau",
        ROOT / "src/server/Persistence.luau",
        ROOT / "src/server/Session.luau",
        *sorted((ROOT / "tests").rglob("*.spec.luau")),
    ]
    run([executable(tools_dir, "luau-analyze"), *map(str, core_files)])
    print("Strict analysis: core modules and behavioral suites passed", flush=True)
    run([executable(tools_dir, "stylua"), "--check", "src", "tests"])
    print("StyLua formatting: passed", flush=True)


def test(tools_dir):
    specs = sorted((ROOT / "tests").rglob("*.spec.luau"))
    if not specs:
        raise RuntimeError("No tests/*.spec.luau suites found; refusing to report success")
    lines = ["local failures = 0", "local suites = {"]
    for spec in specs:
        relative = spec.relative_to(ROOT / "tests").with_suffix("").as_posix()
        lines.append("    { " + json.dumps(relative) + ", " + json.dumps("./" + relative) + " },")
    lines += [
        "}",
        "for _, suite in suites do",
        "    local ok, problem = xpcall(function()",
        "        local runSuite = require(suite[2])",
        '        assert(type(runSuite) == "function", "Spec must return a test function")',
        "        runSuite()",
        "    end, debug.traceback)",
        "    if ok then",
        '        print("PASS " .. suite[1])',
        "    else",
        "        failures += 1",
        '        print("FAIL " .. suite[1] .. "\\n" .. tostring(problem))',
        "    end",
        "end",
        'assert(failures == 0, tostring(failures) .. " test suite(s) failed")',
        'print(tostring(#suites) .. " test suite(s) passed")',
    ]
    # Require paths resolve relative to this file, so keep the transient runner in tests/.
    with tempfile.NamedTemporaryFile(mode="w", prefix=".runner-", suffix=".luau", dir=ROOT / "tests", encoding="utf-8", delete=False) as handle:
        runner = Path(handle.name)
        handle.write("\n".join(lines) + "\n")
    try:
        run([executable(tools_dir, "luau"), str(runner)])
    finally:
        runner.unlink(missing_ok=True)


def build(tools_dir):
    (ROOT / "build").mkdir(exist_ok=True)
    run([executable(tools_dir, "rojo"), "build", "default.project.json", "-o", "build/DriftwoodIsles.rbxlx"])
    verify_place(ROOT / "default.project.json", ROOT / "build/DriftwoodIsles.rbxlx")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("check", "test", "build", "format", "serve", "all"))
    parser.add_argument("--tools-dir", type=Path, default=default_tools_dir())
    args = parser.parse_args()
    directory = args.tools_dir.resolve()
    try:
        if args.action in ("check", "all"):
            check(directory)
        if args.action in ("test", "all"):
            test(directory)
        if args.action in ("build", "all"):
            build(directory)
        if args.action == "format":
            run([executable(directory, "stylua"), "src", "tests"])
        if args.action == "serve":
            run([executable(directory, "rojo"), "serve", "default.project.json"])
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"Development command failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
