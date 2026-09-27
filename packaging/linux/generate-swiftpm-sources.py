#!/usr/bin/env python3
"""Generate Flatpak git sources for the Linux SwiftPM graph.

Reads packaging/linux/Package.resolved (the pins SwiftPM resolves with
SPEAK_LINUX_TARGET=1 on Linux) and writes packaging/linux/swiftpm-sources.json:
one flatpak-builder git source per pin, pinned by tag and commit, checked out
at swiftpm-deps/<identity>. packaging/linux/swiftpm-offline-setup.sh then
points SwiftPM mirrors at those checkouts so the build resolves with no
network, the way Flathub builds.

    packaging/linux/generate-swiftpm-sources.py           # rewrite the JSON
    packaging/linux/generate-swiftpm-sources.py --check   # fail if stale
"""

import argparse
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
RESOLVED = HERE / "Package.resolved"
OUTPUT = HERE / "swiftpm-sources.json"
DEST_ROOT = "swiftpm-deps"


def generate(resolved_path: Path) -> str:
    data = json.loads(resolved_path.read_text(encoding="utf-8"))
    if data.get("version") not in (2, 3):
        raise SystemExit(f"{resolved_path}: unsupported Package.resolved version {data.get('version')}")
    sources = []
    for pin in sorted(data["pins"], key=lambda p: p["identity"]):
        if pin.get("kind") != "remoteSourceControl":
            raise SystemExit(f"{pin['identity']}: only remoteSourceControl pins can be vendored")
        state = pin["state"]
        if "version" not in state:
            raise SystemExit(f"{pin['identity']}: pin by version (branch/revision pins are not reproducible)")
        sources.append({
            "type": "git",
            "url": pin["location"],
            "tag": state["version"],
            "commit": state["revision"],
            "dest": f"{DEST_ROOT}/{pin['identity']}",
        })
    return json.dumps(sources, indent=2) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check", action="store_true", help="fail when the committed JSON is out of date")
    args = parser.parse_args()
    expected = generate(RESOLVED)
    if args.check:
        current = OUTPUT.read_text(encoding="utf-8") if OUTPUT.exists() else ""
        if current != expected:
            print(f"{OUTPUT.relative_to(HERE.parent.parent)} is out of date; run "
                  "packaging/linux/generate-swiftpm-sources.py", file=sys.stderr)
            return 1
        print("swiftpm-sources.json matches packaging/linux/Package.resolved")
        return 0
    OUTPUT.write_text(expected, encoding="utf-8")
    print(f"wrote {OUTPUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
