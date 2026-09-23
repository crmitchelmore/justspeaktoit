#!/usr/bin/env bash
# End-to-end checks of the Linux native adapters against real services in a
# disposable session: a private D-Bus session bus, an unlocked GNOME Keyring,
# PipeWire with pipewire-pulse and a test tone, Xvfb with Openbox and a Zenity
# text field, and a fake XDG desktop portal (scripts/linux-fake-portal.py).
#
#   scripts/linux-integration-checks.sh [path/to/SpeakLinux]
#
# Needs: dbus, gnome-keyring, pipewire, pipewire-pulse, wireplumber,
# pulseaudio-utils, xvfb, openbox, zenity, xdotool, python3-gi.
# What this cannot prove (consent dialogs, compositor indicators, real
# Wayland key delivery) is listed in Docs/linux-development.md.
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
binary="${1:-}"
if [ -z "$binary" ]; then
    binary="$(SPEAK_LINUX_TARGET=1 swift build --package-path "$repo" --show-bin-path)/SpeakLinux"
fi
binary="$(cd "$(dirname "$binary")" && pwd)/$(basename "$binary")"
python="${PYTHON:-python3}"

if [ -z "${JSTI_INTEGRATION_INNER:-}" ]; then
    export JSTI_INTEGRATION_INNER=1
    exec dbus-run-session -- "$0" "$binary"
fi

work="$(mktemp -d)"
export XDG_RUNTIME_DIR="$work/runtime" HOME="$work/home" XDG_DATA_HOME="$work/data"
mkdir -p "$XDG_RUNTIME_DIR" "$HOME" "$XDG_DATA_HOME"
chmod 700 "$XDG_RUNTIME_DIR"
pids=()
cleanup() {
    for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done
    wait 2>/dev/null || true
    rm -rf "$work"
}
trap cleanup EXIT

step() { printf '\n== %s\n' "$1"; }

step "keyring (gnome-keyring, Secret Service)"
printf 'integration' | gnome-keyring-daemon --unlock --components=secrets >/dev/null
"$binary" --integration-test keyring

step "capture (PipeWire through libpulse)"
pipewire >"$work/pipewire.log" 2>&1 & pids+=($!)
sleep 0.5
wireplumber >"$work/wireplumber.log" 2>&1 & pids+=($!)
pipewire-pulse >"$work/pipewire-pulse.log" 2>&1 & pids+=($!)
for _ in $(seq 1 100); do pactl info >/dev/null 2>&1 && break; sleep 0.1; done
pactl load-module module-null-sink sink_name=jsti_test >/dev/null
"$python" - "$work/tone.raw" <<'PY'
import math, struct, sys
with open(sys.argv[1], "wb") as tone:
    tone.write(b"".join(struct.pack("<h", int(12000 * math.sin(2 * math.pi * 440 * n / 16000)))
                        for n in range(16000 * 20)))
PY
pacat --playback --device=jsti_test --format=s16le --rate=16000 --channels=1 "$work/tone.raw" & pids+=($!)
sleep 0.5
if ! JSTI_TEST_SOURCE=jsti_test.monitor "$binary" --integration-test capture; then
    pactl info || true
    pactl list short sinks || true
    pactl list short sources || true
    tail -n 40 "$work/pipewire.log" "$work/wireplumber.log" "$work/pipewire-pulse.log" >&2 || true
    exit 1
fi

step "portals (fake GlobalShortcuts, RemoteDesktop and Clipboard)"
"$python" "$repo/scripts/linux-fake-portal.py" "$work/portal.json" >"$work/portal.out" 2>&1 & pids+=($!)
for _ in $(seq 1 100); do grep -q "fake portal ready" "$work/portal.out" 2>/dev/null && break; sleep 0.1; done
"$binary" --integration-test portal
"$python" - "$work/portal.json" <<'PY'
import json, sys
log = json.load(open(sys.argv[1]))
assert not log["errors"], log["errors"]
assert log["restore_tokens"] == ["", "fake-restore-token-1"], log["restore_tokens"]
assert [s["text"] for s in log["selections"]] == ["Portal dictation ✓", "Second"], log["selections"]
ctrl, shift, v = 0xFFE3, 0xFFE1, 0x76
assert log["keysyms"] == [[ctrl, 1], [v, 1], [v, 0], [ctrl, 0],
                          [ctrl, 1], [shift, 1], [v, 1], [v, 0], [shift, 0], [ctrl, 0]], log["keysyms"]
assert log["calls"].count("Session.Close") >= 3, log["calls"]
print("Fake portal saw the expected sessions, restore tokens, selections and keysyms.")
PY

step "X11 paste (Xvfb, Openbox, Zenity)"
display=":$((80 + RANDOM % 9))"
Xvfb "$display" -screen 0 1280x1024x24 -nolisten tcp >/dev/null 2>&1 & pids+=($!)
for _ in $(seq 1 50); do [ -e "/tmp/.X11-unix/X${display#:}" ] && break; sleep 0.1; done
export DISPLAY="$display" GDK_BACKEND=x11 GSK_RENDERER=cairo GTK_A11Y=none NO_AT_BRIDGE=1 LANG=C.UTF-8 LC_ALL=C.UTF-8
openbox >/dev/null 2>&1 & pids+=($!)
sleep 0.5
JSTI_TEST_READY_FILE="$work/grab-ready" "$binary" --integration-test x11-hotkey & grab=$!
for _ in $(seq 1 100); do [ -e "$work/grab-ready" ] && break; sleep 0.05; done
xdotool key ctrl+alt+space
wait "$grab"

zenity --entry --title "JSTI target" --text "Paste here" >"$work/zenity.out" 2>/dev/null & zenity=$!
pids+=($zenity)
target="$(xdotool search --sync --name 'JSTI target' | head -1)"
JSTI_TEST_TARGET_WINDOW="$target" "$binary" --integration-test x11 & app=$!
# Raise the target once the app's own window has taken focus.
xdotool search --sync --name '^JustSpeakToIt$' >/dev/null
sleep 0.3
xdotool windowactivate --sync "$target"
wait "$app"
xdotool windowactivate --sync "$target" key --clearmodifiers Return
wait "$zenity" || true
pasted="$(cat "$work/zenity.out")"
[ "$pasted" = "X11 dictation ✓" ] || { echo "The target received: '$pasted'" >&2; exit 1; }
echo "The Zenity field received the dictated text."

step "all Linux integration checks passed"
