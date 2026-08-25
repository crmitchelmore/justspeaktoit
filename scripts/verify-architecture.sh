#!/usr/bin/env bash
# Verify that a packaged JustSpeakToIt.app contains exactly the CPU slices its
# release variant promises (issue #774).
#
# Usage: ./scripts/verify-architecture.sh <path-to-JustSpeakToIt.app> <arm64|universal> [embedded-cli|no-embedded-cli]
#
# The main executable is enforced: the arm64 primary download must not carry
# an x86_64 slice, and the universal legacy download must carry both. The
# embedded `speak` CLI is enforced the same way when the variant ships one
# (`embedded-cli`, the default, for the legacy download) and must be absent
# when it does not (`no-embedded-cli`: the primary download distributes the CLI
# separately, issue #775). Embedded frameworks are reported for the log but not
# enforced; third-party binaries (Sparkle) ship universal.

set -euo pipefail

APP_PATH="${1:-}"
VARIANT="${2:-}"
CLI_MODE="${3:-embedded-cli}"

if [[ -z "$APP_PATH" || -z "$VARIANT" ]]; then
    echo "Usage: $0 <path-to-JustSpeakToIt.app> <arm64|universal> [embedded-cli|no-embedded-cli]" >&2
    exit 1
fi

case "$CLI_MODE" in
    embedded-cli|no-embedded-cli) ;;
    *)
        echo "error: unknown CLI mode '$CLI_MODE' (expected embedded-cli or no-embedded-cli)" >&2
        exit 1
        ;;
esac

if [[ ! -d "$APP_PATH" ]]; then
    echo "error: app bundle not found at $APP_PATH" >&2
    exit 1
fi

case "$VARIANT" in
    arm64) EXPECTED="arm64" ;;
    universal) EXPECTED="arm64 x86_64" ;;
    *)
        echo "error: unknown variant '$VARIANT' (expected arm64 or universal)" >&2
        exit 1
        ;;
esac

sorted_archs() {
    tr ' ' '\n' <<<"$1" | sed '/^$/d' | sort | tr '\n' ' ' | sed 's/ $//'
}

check_binary() {
    local binary="$1"
    if [[ ! -f "$binary" ]]; then
        echo "error: executable missing at $binary" >&2
        exit 1
    fi
    local archs
    archs="$(lipo -archs "$binary")"
    if [[ "$(sorted_archs "$archs")" != "$(sorted_archs "$EXPECTED")" ]]; then
        echo "error: $binary contains [$archs] but the $VARIANT variant must contain exactly [$EXPECTED]" >&2
        exit 1
    fi
    echo "==> $(basename "$binary"): $archs"
}

check_binary "$APP_PATH/Contents/MacOS/JustSpeakToIt"
if [[ "$CLI_MODE" == "embedded-cli" ]]; then
    check_binary "$APP_PATH/Contents/MacOS/speak"
elif [[ -e "$APP_PATH/Contents/MacOS/speak" ]]; then
    echo "error: the $VARIANT variant must not embed Contents/MacOS/speak (the CLI is distributed separately)" >&2
    exit 1
else
    echo "==> speak: not embedded (distributed separately)"
fi

for framework in "$APP_PATH"/Contents/Frameworks/*.framework; do
    [[ -d "$framework" ]] || continue
    name="$(basename "$framework" .framework)"
    binary="$framework/$name"
    [[ -f "$binary" ]] || binary="$framework/Versions/A/$name"
    [[ -f "$binary" ]] || continue
    echo "    framework $name: $(lipo -archs "$binary") (not enforced)"
done

echo "==> Architecture verified for the $VARIANT variant"
