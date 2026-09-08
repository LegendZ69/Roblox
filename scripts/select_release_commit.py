#!/usr/bin/env python3
"""Select an exact reviewed main-history commit for release or draft resumption.

Run this selector from a fresh checkout of main before running any scripts from
the requested commit. It never fetches, moves a branch, or accepts arbitrary refs.
"""

import argparse
import os
from pathlib import Path
import re
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
COMMIT = re.compile(r"[0-9a-f]{40}")


def git(root, *arguments):
    result = subprocess.run(
        ["git", *arguments], cwd=root, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    if result.returncode:
        raise RuntimeError(f"Git could not validate the release checkout ({arguments[0]})")
    return result.stdout.decode("utf-8").strip()


def require_clean(root):
    if git(root, "status", "--porcelain", "--untracked-files=all"):
        raise RuntimeError("Release selection requires a clean checkout, including untracked files")


def select_release_commit(root, requested_commit):
    """Detach at a full commit SHA only when it belongs to fetched origin/main."""
    if not isinstance(requested_commit, str) or COMMIT.fullmatch(requested_commit) is None:
        raise RuntimeError("Release commit must be an exact full lowercase 40-character Git commit SHA")
    require_clean(root)
    if git(root, "cat-file", "-t", requested_commit) != "commit":
        raise RuntimeError("The requested release object must be a commit")
    try:
        reviewed_main = git(root, "rev-parse", "--verify", "refs/remotes/origin/main^{commit}")
    except RuntimeError as error:
        raise RuntimeError("Fetch origin/main before selecting a reviewed release commit") from error
    ancestry = subprocess.run(
        ["git", "merge-base", "--is-ancestor", requested_commit, reviewed_main],
        cwd=root, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    if ancestry.returncode:
        raise RuntimeError("The requested release commit must belong to fetched origin/main history")
    # Recheck before checkout; no forced switch can discard local changes.
    require_clean(root)
    git(root, "checkout", "--detach", requested_commit)
    selected = git(root, "rev-parse", "HEAD")
    if selected != requested_commit:
        raise RuntimeError("Git did not select the exact requested release commit")
    require_clean(root)
    return selected


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--commit", required=True)
    args = parser.parse_args()
    try:
        selected = select_release_commit(ROOT, args.commit)
        output_path = os.environ.get("GITHUB_OUTPUT")
        if output_path:
            with open(output_path, "a", encoding="utf-8") as output:
                output.write(f"commit={selected}\n")
    except (OSError, RuntimeError) as error:
        print(f"Release selection failed: {error}", file=sys.stderr)
        return 1
    print(f"Selected reviewed release commit: {selected}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
