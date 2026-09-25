#!/usr/bin/env bash
# Runs the Linux desktop app's self-test and its GTK window smoke test under a
# private X server and session bus. Used by CI and for local checks.
#
#   scripts/linux-desktop-checks.sh [path/to/SpeakLinux]
#
# Set JSTI_UI_SNAPSHOT_PATH to also save a PNG of the smoke-test window.
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
binary="${1:-}"
if [ -z "$binary" ]; then
    binary="$(SPEAK_LINUX_TARGET=1 swift build --package-path "$repo" --show-bin-path)/SpeakLinux"
fi
[ -x "$binary" ] || { echo "SpeakLinux binary not found at $binary" >&2; exit 1; }

echo "== native self-test"
"$binary" --self-test

echo "== window smoke test (Xvfb, private session bus)"
display=":$((90 + RANDOM % 9))"
Xvfb "$display" -screen 0 1280x1024x24 -nolisten tcp >/dev/null 2>&1 &
xvfb=$!
trap 'kill "$xvfb" 2>/dev/null || true' EXIT
for _ in $(seq 1 50); do
    [ -e "/tmp/.X11-unix/X${display#:}" ] && break
    sleep 0.1
done
DISPLAY="$display" GDK_BACKEND=x11 GSK_RENDERER=cairo GTK_A11Y=none NO_AT_BRIDGE=1 \
    timeout 120 dbus-run-session -- "$binary" --ui-smoke-test
