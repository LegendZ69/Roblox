#!/usr/bin/env python3
"""Install checksum-pinned official tools; requires Python 3.9+ and internet access."""

import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import sys
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = json.loads((ROOT / "scripts" / "toolchain.json").read_text())


def default_tools_dir():
    return Path(os.environ.get("DRIFTWOOD_TOOLS_DIR", str(ROOT / ".tools"))).resolve()


def platform_key():
    system = {"Linux": "linux", "Darwin": "macos", "Windows": "windows"}.get(platform.system())
    machine = {"x86_64": "x86_64", "AMD64": "x86_64", "arm64": "aarch64", "aarch64": "aarch64"}.get(platform.machine())
    key = f"{system}-{machine}"
    if any(key not in tool["assets"] for tool in MANIFEST.values()):
        raise RuntimeError(f"No complete pinned toolchain for {platform.system()} {platform.machine()}. Use Linux x86_64, macOS, or Windows x86_64.")
    return key


def install(destination):
    key = platform_key()
    destination.mkdir(parents=True, exist_ok=True)
    suffix = ".exe" if platform.system() == "Windows" else ""
    for name, tool in MANIFEST.items():
        asset, checksum = tool["assets"][key]
        marker = destination / f".{name}-version.json"
        identity = {"version": tool["version"], "platform": key, "sha256": checksum}
        expected = [executable + suffix for executable in tool["executables"]]
        if marker.exists() and json.loads(marker.read_text()) == identity and all((destination / exe).is_file() for exe in expected):
            print(f"{name} {tool['version']} already installed", flush=True)
            continue
        url = f"https://github.com/{tool['repository']}/releases/download/{tool['tag']}/{asset}"
        print(f"Downloading {name} {tool['version']} ({key})", flush=True)
        request = urllib.request.Request(url, headers={"User-Agent": "Driftwood-Isles-toolchain"})
        with urllib.request.urlopen(request, timeout=60) as response:
            content = response.read()
        if hashlib.sha256(content).hexdigest() != checksum:
            raise RuntimeError(f"SHA-256 mismatch for {asset}; tool was not installed")
        with zipfile.ZipFile(io.BytesIO(content)) as archive:
            members = {Path(member.filename).name: member for member in archive.infolist() if not member.is_dir()}
            missing = set(expected) - members.keys()
            if missing:
                raise RuntimeError(f"Missing executables in {asset}: {sorted(missing)}")
            for executable in expected:
                target = destination / executable
                target.write_bytes(archive.read(members[executable]))
                target.chmod(0o755)
        marker.write_text(json.dumps(identity, indent=2) + "\n")
        print(f"Installed {name} {tool['version']}", flush=True)
    print(f"Tools ready: {destination}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--destination", type=Path, default=default_tools_dir())
    args = parser.parse_args()
    try:
        install(args.destination.resolve())
    except (OSError, RuntimeError, ValueError, zipfile.BadZipFile) as error:
        print(f"Tool setup failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
