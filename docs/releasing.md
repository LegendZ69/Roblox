# Versioned GitHub releases

This repository contains one application: Driftwood Isles. GitHub releases distribute its source and a Roblox Studio place. They do not publish or update a Roblox experience.

## Prepare a version

1. Update `VERSION` with a new semantic version, such as `0.1.0-alpha.2`.
2. Set `tree.ReplicatedStorage.ReleaseVersion.$properties.Value` in `default.project.json` to the same version.
3. Record the changes in `CHANGELOG.md` and add `docs/releases/<version>.md` with release notes and current validation limits.
4. Run the checks below, review the change, commit, and push it. CI tests the game and packaging on the pull request.
5. Merge the reviewed version change into `main`. A push changing `VERSION` starts **Publish versioned release**. A manual run from `main` can resume an interrupted release.

```sh
python3 scripts/bootstrap_tools.py
python3 scripts/dev.py all
python3 -m unittest discover -s scripts -p 'test_*.py'
# Commit the reviewed source before packaging; the working tree must be clean.
python3 scripts/package_release.py
```

The default output directory is `build/release`. It must not already exist. For a reproducibility check, use a different fresh directory with `--output`; do not mix files from different versions. The source commit, source tree, pinned tool versions, artifact sizes, and hashes are recorded in `release-manifest.json`. Packaging checks the project mapping and every mapped source against the actual Git commit, including ignored files and index-hidden edits. It verifies source embedding and version identity but does not itself claim that tests or Studio ran.

## Publication behavior

Only the release job receives `contents: write`; pull-request validation has read-only permissions. The workflow checks out the exact triggering commit, runs the full game pipeline and release-tool tests, packages it, and uploads all release files. The publisher verifies the source commit and local checksums before using GitHub's release API.

Assets are uploaded to a draft first. Publication happens only after every asset is confirmed. An interrupted draft can resume when existing assets match exactly. A conflicting tag, commit, or asset stops publication. Published assets are never overwritten; corrections use a new version. Versions with an alpha/beta/rc suffix are marked as prereleases. This sequence uses GitHub's documented [release](https://docs.github.com/en/rest/releases/releases) and [asset upload](https://docs.github.com/en/rest/releases/assets) endpoints.

## Verify the result

Confirm the release tag resolves to the intended commit and the release workflow succeeded. Download the assets, then run `sha256sum -c SHA256SUMS` from their directory (or compare SHA-256 hashes with the equivalent tool on your OS). The setup ZIP contains its own manifest and checksums for its included files.

Keep [Studio/device validation](studio-validation.md) and the release notes explicit about pending checks. Versioned cloud builds establish source, rules, and package integrity; rendering, physics, actual clients, DataStore networking, and device performance require their respective runtime environments.
