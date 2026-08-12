#!/usr/bin/env bash
# Build the `speak` automation CLI and embed it inside JustSpeakToIt.app.
#
# Usage: ./Scripts/build-speak-cli.sh <path-to-JustSpeakToIt.app> [signing-identity]
#
# The CLI is a thin client for the automation socket the app exposes, so it must
# ship with the app rather than as an independent download: the Homebrew cask
# links `Contents/MacOS/speak` onto the user's PATH.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${1:-}"
SIGN_IDENTITY="${2:-}"

if [[ -z "$APP_PATH" ]]; then
    echo "Usage: $0 <path-to-JustSpeakToIt.app> [signing-identity]" >&2
    exit 1
fi

if [[ ! -d "$APP_PATH" ]]; then
    echo "error: app bundle not found at $APP_PATH" >&2
    exit 1
fi

cd "$ROOT_DIR"

echo "==> Building speak (release, arm64+x86_64)"
swift build --product speak --configuration release \
    --arch arm64 --arch x86_64

BINARY_PATH="$(swift build --product speak --configuration release \
    --arch arm64 --arch x86_64 --show-bin-path)/speak"

if [[ ! -f "$BINARY_PATH" ]]; then
    echo "error: built binary missing at $BINARY_PATH" >&2
    exit 1
fi

DESTINATION="$APP_PATH/Contents/MacOS/speak"
echo "==> Embedding $BINARY_PATH -> $DESTINATION"
cp "$BINARY_PATH" "$DESTINATION"
chmod 755 "$DESTINATION"

if [[ -n "$SIGN_IDENTITY" ]]; then
    echo "==> Signing embedded CLI with '$SIGN_IDENTITY'"
    codesign --force --timestamp --options runtime \
        --sign "$SIGN_IDENTITY" \
        "$DESTINATION"
    codesign -dv --verbose=4 "$DESTINATION" 2>&1 | grep -q "runtime"
    echo "==> Hardened runtime confirmed for embedded CLI"
else
    echo "==> Skipping codesign (no identity supplied)"
fi

"$DESTINATION" --version
echo "==> speak embedded successfully"
