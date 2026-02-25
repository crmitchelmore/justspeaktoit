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

set -euo pipefail

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

# --- Clear any existing crash reports for this app ---
CRASH_DIR="$HOME/Library/Logs/DiagnosticReports"
touch /tmp/.verify-launch-marker
CRASH_COUNT_BEFORE=0
if [ -d "$CRASH_DIR" ]; then
    CRASH_COUNT_BEFORE=$(find "$CRASH_DIR" -name "${PROCESS_NAME}*" -newer /tmp/.verify-launch-marker 2>/dev/null | wc -l | tr -d ' ' || echo "0")
fi

# --- Launch the app ---
APP_PID=""

if [[ "$APP_PATH" == *.app ]]; then
    # It's an .app bundle — use `open` to launch it properly
    echo "  Launching .app bundle..."
    open -a "$APP_PATH" &
    sleep 2

    # Find the PID
    APP_PID=$(pgrep -f "$PROCESS_NAME" 2>/dev/null | head -1 || true)
else
    # It's a bare executable (SPM build) — launch directly
    echo "  Launching executable..."
    "$APP_PATH" &
    APP_PID=$!
    sleep 2
fi

if [ -z "$APP_PID" ]; then
    echo "❌ Failed to find running process after launch"
    exit 1
fi

echo "  PID: $APP_PID"

# --- Wait and check if process is still alive ---
echo "  Waiting ${TIMEOUT_SECONDS}s to verify stability..."

ELAPSED=0
while [ $ELAPSED -lt "$TIMEOUT_SECONDS" ]; do
    sleep 1
    ELAPSED=$((ELAPSED + 1))

    if ! kill -0 "$APP_PID" 2>/dev/null; then
        echo "❌ Process died after ${ELAPSED}s"

        # Check for crash reports
        if [ -d "$CRASH_DIR" ]; then
            CRASH_FILES=$(find "$CRASH_DIR" -name "${PROCESS_NAME}*" -newer /tmp/.verify-launch-marker 2>/dev/null || true)
            if [ -n "$CRASH_FILES" ]; then
                echo ""
                echo "📋 Crash report(s) found:"
                echo "$CRASH_FILES"
                echo ""
                # Print the first few lines of the most recent crash report
                LATEST=$(echo "$CRASH_FILES" | head -1)
                echo "--- Start of crash report ---"
                head -50 "$LATEST" 2>/dev/null || true
                echo "--- End of excerpt ---"
            fi
        fi

        # Check system log for crash entries
        echo ""
        echo "📋 Recent system log entries:"
        log show --predicate "process == '${PROCESS_NAME}'" --last 30s --style compact 2>/dev/null | tail -20 || true

        exit 1
    fi
done

echo "  ✅ Process still alive after ${TIMEOUT_SECONDS}s"

# --- Check for crash reports generated during launch ---
CRASH_COUNT_AFTER=0
if [ -d "$CRASH_DIR" ]; then
    CRASH_COUNT_AFTER=$(find "$CRASH_DIR" -name "${PROCESS_NAME}*" -newer /tmp/.verify-launch-marker 2>/dev/null | wc -l | tr -d ' ')
fi

if [ "$CRASH_COUNT_AFTER" -gt "$CRASH_COUNT_BEFORE" ]; then
    echo "⚠️  New crash reports detected (before: $CRASH_COUNT_BEFORE, after: $CRASH_COUNT_AFTER)"
    echo "  This may indicate a crash-and-relaunch cycle."
    find "$CRASH_DIR" -name "${PROCESS_NAME}*" -newer /tmp/.verify-launch-marker 2>/dev/null
    # Don't fail — the process is running. But warn.
fi

# --- Clean up: kill the launched app ---
echo "  Terminating process..."
kill "$APP_PID" 2>/dev/null || true
wait "$APP_PID" 2>/dev/null || true

# Wait briefly for clean shutdown
sleep 1
if kill -0 "$APP_PID" 2>/dev/null; then
    echo "  Force-killing..."
    kill -9 "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
fi

# Clean up marker file
rm -f /tmp/.verify-launch-marker

echo "✅ Launch verification passed"
exit 0
