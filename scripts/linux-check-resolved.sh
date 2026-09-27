#!/usr/bin/env bash
# Fails when packaging/linux/Package.resolved no longer satisfies Package.swift
# for the Linux graph (SPEAK_LINUX_TARGET=1), or when the Flatpak's vendored
# SwiftPM sources or whisper.cpp pin have drifted from their sources of truth.
#
#   scripts/linux-check-resolved.sh            # check (CI)
#   scripts/linux-check-resolved.sh --update   # re-resolve on Linux, rewrite the
#                                              # resolved file and swiftpm-sources.json
#
# Works in a scratch copy, so the checkout's Apple-graph Package.resolved is
# never touched. Needs network access (SwiftPM fetches the pinned revisions)
# and python3.
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
resolved="$repo/packaging/linux/Package.resolved"
update=0
[ "${1:-}" = "--update" ] && update=1

if [ "$update" = 1 ]; then
    [ "$(uname -s)" = Linux ] || { echo "--update must run on Linux (the graph is host-dependent)" >&2; exit 1; }
    scratch="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/jsti-linux-resolve.XXXXXX")"
    trap 'rm -rf "$scratch"' EXIT
    tar -C "$repo" --exclude=./.build --exclude=./Tooling/.build --exclude=./.git \
        --exclude=./swiftpm-deps --exclude=./.flatpak-builder -cf - . | tar -C "$scratch" -xf -
    rm -f "$scratch/Package.resolved" "$scratch/.swiftpm/configuration/mirrors.json"
    SPEAK_LINUX_TARGET=1 swift package --package-path "$scratch" resolve
    cp "$scratch/Package.resolved" "$resolved"
    python3 "$repo/packaging/linux/generate-swiftpm-sources.py"
    echo "Updated $resolved; review the diff, then run $0 to check it."
    exit 0
fi

echo "== Flatpak SwiftPM sources match packaging/linux/Package.resolved"
python3 "$repo/packaging/linux/generate-swiftpm-sources.py" --check

echo "== Flatpak whisper.cpp pin matches scripts/windows-local-runtime/dependencies.json"
python3 - "$repo" <<'PY'
import json, re, sys
from pathlib import Path
repo = Path(sys.argv[1])
pin = json.loads((repo / "scripts/windows-local-runtime/dependencies.json").read_text())["whisperCpp"]
manifest = (repo / "packaging/linux/com.justspeaktoit.JustSpeakToIt.yml").read_text()
build_script = (repo / "scripts/linux-build-whisper.sh").read_text()
problems = []
for name, text in (("Flatpak manifest", manifest), ("scripts/linux-build-whisper.sh", build_script)):
    if pin["commit"] not in text:
        problems.append(f"{name} does not pin whisper.cpp commit {pin['commit']}")
    if not re.search(r"\b" + re.escape(pin["tag"]) + r"\b", text):
        problems.append(f"{name} does not name whisper.cpp tag {pin['tag']}")
if problems:
    sys.exit("\n".join(problems))
print(f"whisper.cpp {pin['tag']} ({pin['commit'][:12]}) everywhere")
PY

scratch_root="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
scratch="$(mktemp -d "$scratch_root/jsti-linux-resolved.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
tar -C "$repo" --exclude=./.build --exclude=./Tooling/.build --exclude=./.git \
    --exclude=./swiftpm-deps --exclude=./.flatpak-builder -cf - . | tar -C "$scratch" -xf -
cp "$resolved" "$scratch/Package.resolved"
rm -rf "$scratch/.swiftpm/configuration/mirrors.json"

echo "== SwiftPM accepts the Linux resolved file without re-resolving"
# --force-resolved-versions refuses to resolve: it fails if a pin is missing or
# no longer satisfies a requirement in Package.swift.
SPEAK_LINUX_TARGET=1 swift package --package-path "$scratch" resolve --force-resolved-versions
if ! cmp -s "$resolved" "$scratch/Package.resolved"; then
    diff -u "$resolved" "$scratch/Package.resolved" || true
    echo "SwiftPM rewrote the Linux resolved file; regenerate it (see Docs/linux-packaging.md)" >&2
    exit 1
fi

echo "== Every pin is used by the Linux graph"
SPEAK_LINUX_TARGET=1 swift package --package-path "$scratch" show-dependencies --format json \
    >"$scratch/.jsti-dependencies.json"
python3 - "$resolved" "$scratch/.jsti-dependencies.json" <<'PY'
import json, sys
pins = {p["identity"] for p in json.load(open(sys.argv[1]))["pins"]}
def walk(node, seen):
    for dep in node.get("dependencies", []):
        seen.add(dep["identity"])
        walk(dep, seen)
    return seen
graph = walk(json.load(open(sys.argv[2])), set())
if pins != graph:
    sys.exit(f"pins {sorted(pins)} differ from the Linux graph {sorted(graph)}")
print("pins:", ", ".join(sorted(pins)))
PY
echo "packaging/linux/Package.resolved is current"
