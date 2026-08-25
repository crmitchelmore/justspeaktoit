#!/usr/bin/env bash
# Record the download and install size of one release variant, so growth is
# visible in every release run (issue #774).
#
# Usage: ./scripts/record-release-size.sh <arm64|universal> <path-to-app> <path-to-dmg>
#
# Prints one Markdown table row and appends it to $GITHUB_STEP_SUMMARY when
# running in GitHub Actions. The table header is written by the workflow.

set -euo pipefail

VARIANT="${1:-}"
APP_PATH="${2:-}"
DMG_PATH="${3:-}"

if [[ -z "$VARIANT" || -z "$APP_PATH" || -z "$DMG_PATH" ]]; then
    echo "Usage: $0 <arm64|universal> <path-to-app> <path-to-dmg>" >&2
    exit 1
fi

for path in "$APP_PATH" "$DMG_PATH"; do
    if [[ ! -e "$path" ]]; then
        echo "error: not found: $path" >&2
        exit 1
    fi
done

MAIN_BINARY="$APP_PATH/Contents/MacOS/JustSpeakToIt"
CLI_BINARY="$APP_PATH/Contents/MacOS/speak"

bytes() { stat -f%z "$1"; }
megabytes() { awk -v b="$1" 'BEGIN { printf "%.1f", b / 1048576 }'; }

DMG_BYTES="$(bytes "$DMG_PATH")"
APP_KB="$(du -sk "$APP_PATH" | awk '{print $1}')"
APP_BYTES=$((APP_KB * 1024))
MAIN_BYTES="$(bytes "$MAIN_BINARY")"
ARCHS="$(lipo -archs "$MAIN_BINARY")"
# The primary download no longer embeds the CLI (issue #775); its standalone
# archives are measured by build-speak-cli-standalone.sh.
if [[ -f "$CLI_BINARY" ]]; then
    CLI_CELL="$(megabytes "$(bytes "$CLI_BINARY")") MB"
else
    CLI_CELL="not embedded"
fi

ROW="| $VARIANT | $(megabytes "$DMG_BYTES") MB | $(megabytes "$APP_BYTES") MB | $(megabytes "$MAIN_BYTES") MB | $CLI_CELL | $ARCHS |"
echo "$ROW"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    echo "$ROW" >> "$GITHUB_STEP_SUMMARY"
fi
