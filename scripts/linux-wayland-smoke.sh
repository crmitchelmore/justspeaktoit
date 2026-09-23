#!/usr/bin/env bash
# Runs the GTK window smoke test on Wayland under a headless Weston, so the
# window, its thread-safe updates and shutdown are checked without X11.
#
#   scripts/linux-wayland-smoke.sh [path/to/SpeakLinux]
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
binary="${1:-$(SPEAK_LINUX_TARGET=1 swift build --package-path "$repo" --show-bin-path)/SpeakLinux}"
runtime="$(mktemp -d)"
chmod 700 "$runtime"
export XDG_RUNTIME_DIR="$runtime"
weston --backend=headless-backend.so --socket=jsti-wayland --idle-time=0 >"$runtime/weston.log" 2>&1 &
weston=$!
# The document portal may leave a FUSE mount in the runtime directory.
trap 'kill "$weston" 2>/dev/null || true; fusermount -u "$runtime/doc" 2>/dev/null || true; rm -rf "$runtime" 2>/dev/null || true' EXIT
for _ in $(seq 1 100); do [ -S "$runtime/jsti-wayland" ] && break; sleep 0.05; done
[ -S "$runtime/jsti-wayland" ] || { cat "$runtime/weston.log" >&2; exit 1; }
env -u DISPLAY WAYLAND_DISPLAY=jsti-wayland XDG_SESSION_TYPE=wayland GDK_BACKEND=wayland GSK_RENDERER=cairo \
    GTK_A11Y=none timeout 120 dbus-run-session -- "$binary" --ui-smoke-test
