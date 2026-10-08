#!/bin/bash
# verify-launch.sh — Verify that a built macOS app launches without crashing.
#
# Usage:
#   ./scripts/verify-launch.sh /path/to/JustSpeakToIt.app
#   ./scripts/verify-launch.sh  # defaults to .build/release/SpeakApp
#
# Exit codes:
#   0 — App launched successfully and stayed alive for the verification period
#   1 — App crashed, failed to launch, or was not found
#
# This script is designed to run in CI (GitHub Actions macOS runners) and locally.
# It does NOT require accessibility permissions or user interaction.
# Failure evidence is saved to VERIFY_LAUNCH_DIAGNOSTICS_DIR (or a temporary
# directory); VERIFY_LAUNCH_DIAGNOSTICS_WAIT bounds crash-report delivery polling.

set -euo pipefail

# --- Timing helpers ---
if [[ "$(date +%s%N 2>/dev/null)" == *N* ]]; then
    _now_ns() { python3 -c 'import time; print(time.time_ns())'; }
else
    _now_ns() { date +%s%N; }
fi

TIMEOUT_SECONDS="${VERIFY_LAUNCH_TIMEOUT:-8}"
PROCESS_NAME="JustSpeakToIt"

# --- Determine app path ---
if [ $# -ge 1 ]; then
    APP_PATH="$1"
else
    # Default: look for the SPM-built binary
    if [ -f ".build/release/SpeakApp" ]; then
        APP_PATH=".build/release/SpeakApp"
    else
        echo "❌ No app path provided and no default found."
        echo "Usage: $0 /path/to/JustSpeakToIt.app"
        exit 1
    fi
fi

echo "🔍 Verifying launch: $APP_PATH"

# --- Validate the path exists ---
if [ ! -e "$APP_PATH" ]; then
    echo "❌ App not found at: $APP_PATH"
    exit 1
fi

# Resolve the candidate executable, then launch it directly so $! identifies
# exactly the process we own. A name lookup can accept or kill another install.
APP_EXECUTABLE="$(python3 - "$APP_PATH" <<'PYTHON'
import pathlib, plistlib, sys
path = pathlib.Path(sys.argv[1]).resolve()
if path.suffix == '.app':
    with (path / 'Contents/Info.plist').open('rb') as handle:
        executable = plistlib.load(handle)['CFBundleExecutable']
    path = path / 'Contents/MacOS' / executable
print(path)
PYTHON
)"
if [ ! -x "$APP_EXECUTABLE" ]; then
    echo "❌ Candidate executable is missing or not executable: $APP_EXECUTABLE"
    exit 1
fi
PROCESS_NAME="$(basename "$APP_EXECUTABLE")"
APP_BUNDLE_ID="$(python3 - "$APP_PATH" <<'PYTHON'
import pathlib, plistlib, sys
path = pathlib.Path(sys.argv[1])
if path.suffix == '.app':
    with (path / 'Contents/Info.plist').open('rb') as handle:
        print(plistlib.load(handle).get('CFBundleIdentifier', ''))
PYTHON
)"
APP_PID=""
CRASH_MARKER="$(mktemp "${TMPDIR:-/tmp}/verify-launch.XXXXXX")"
PROCESS_OUTPUT="$(mktemp "${TMPDIR:-/tmp}/verify-launch-output.XXXXXX")"
OUTPUT_FIFO="$(mktemp "${TMPDIR:-/tmp}/verify-launch-fifo.XXXXXX")"
rm -f "$OUTPUT_FIFO"
mkfifo "$OUTPUT_FIFO"
CAPTURE_PID=""
verify_capture_alive() {
    if ! kill -0 "$CAPTURE_PID" 2>/dev/null; then
        echo "❌ Output capture failed; launch cannot be verified"
        exit 1
    fi
}
finish_capture() {
    if [ -n "$CAPTURE_PID" ]; then
        kill "$CAPTURE_PID" 2>/dev/null || true
        for _ in {1..10}; do
            if ! kill -0 "$CAPTURE_PID" 2>/dev/null; then break; fi
            sleep 0.1
        done
        if kill -0 "$CAPTURE_PID" 2>/dev/null; then
            kill -9 "$CAPTURE_PID" 2>/dev/null || true
        fi
        wait "$CAPTURE_PID" 2>/dev/null || true
        CAPTURE_PID=""
    fi
}
cleanup() {
    if [ -n "$APP_PID" ]; then
        kill "$APP_PID" 2>/dev/null || true
        sleep 1
        if kill -0 "$APP_PID" 2>/dev/null; then
            kill -9 "$APP_PID" 2>/dev/null || true
        fi
        wait "$APP_PID" 2>/dev/null || true
    fi
    finish_capture
    rm -f "$CRASH_MARKER" "$PROCESS_OUTPUT" "$OUTPUT_FIFO"
}
trap cleanup EXIT

collect_failure_diagnostics() {
    FAILURE_END_NS=$(_now_ns)
    CHILD_PID="$APP_PID"
    CHILD_STATUS=0
    wait "$CHILD_PID" 2>/dev/null || CHILD_STATUS=$?
    # The child is reaped; never send cleanup signals to a potentially reused PID.
    APP_PID=""
    finish_capture
    echo "  Candidate PID: $CHILD_PID; exit status: $CHILD_STATUS"
    DIAGNOSTICS_DIR="${VERIFY_LAUNCH_DIAGNOSTICS_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/verify-launch-diagnostics.XXXXXX")}"
    mkdir -p "$DIAGNOSTICS_DIR"
    printf 'executable=%s\npid=%s\nexit_status=%s\n' \
        "$APP_EXECUTABLE" "$CHILD_PID" "$CHILD_STATUS" > "$DIAGNOSTICS_DIR/launch.txt"
    python3 -B "$(dirname "$0")/collect-launch-diagnostics.py" \
        --pid "$CHILD_PID" --name "$PROCESS_NAME" --marker "$CRASH_MARKER" \
        --executable "$APP_EXECUTABLE" --start-ns "$LAUNCH_START_NS" --end-ns "$FAILURE_END_NS" \
        --bundle-id "$APP_BUNDLE_ID" \
        --stdout "$PROCESS_OUTPUT" --output "$DIAGNOSTICS_DIR" \
        --wait "${VERIFY_LAUNCH_DIAGNOSTICS_WAIT:-10}" \
        || echo "⚠️ Launch diagnostic collection failed"
}

# --- Launch the app ---
python3 -B "$(dirname "$0")/launch_diagnostics.py" "$OUTPUT_FIFO" "$PROCESS_OUTPUT" &
CAPTURE_PID=$!
LAUNCH_START_NS=$(_now_ns)
echo "  Launching candidate executable..."
"$APP_EXECUTABLE" > "$OUTPUT_FIFO" 2>&1 &
APP_PID=$!
sleep 2

if ! kill -0 "$APP_PID" 2>/dev/null; then
    echo "❌ Candidate process exited during launch"
    collect_failure_diagnostics
    exit 1
fi
verify_capture_alive

echo "  PID: $APP_PID"

# --- Record launch time ---
LAUNCH_END_NS=$(_now_ns)
LAUNCH_ELAPSED_NS=$((LAUNCH_END_NS - LAUNCH_START_NS))
LAUNCH_TIME_S=$(awk "BEGIN {printf \"%.1f\", $LAUNCH_ELAPSED_NS / 1000000000}")
echo "  Launch time: ${LAUNCH_TIME_S}s"
echo "$LAUNCH_TIME_S" > /tmp/launch-time.txt
if [ -f ".launch-time-baseline" ]; then
    BASELINE=$(cat .launch-time-baseline)
    if awk "BEGIN {exit !($LAUNCH_TIME_S > 2 * $BASELINE)}"; then
        echo "  ⚠️ Launch time regression: ${LAUNCH_TIME_S}s (baseline: ${BASELINE}s)"
    fi
fi

# --- Wait and check if process is still alive ---
echo "  Waiting ${TIMEOUT_SECONDS}s to verify stability..."

ELAPSED=0
while [ $ELAPSED -lt "$TIMEOUT_SECONDS" ]; do
    sleep 1
    ELAPSED=$((ELAPSED + 1))

    if ! kill -0 "$APP_PID" 2>/dev/null; then
        echo "❌ Process died after ${ELAPSED}s"

        collect_failure_diagnostics
        exit 1
    fi
    verify_capture_alive
done

echo "  ✅ Process still alive after ${TIMEOUT_SECONDS}s"

# The EXIT trap terminates only the child this invocation launched.
echo "✅ Launch verification passed"
exit 0
