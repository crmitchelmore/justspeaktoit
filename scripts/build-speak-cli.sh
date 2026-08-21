#!/usr/bin/env bash
# Build the `speak` automation CLI and embed it inside JustSpeakToIt.app.
#
# Usage: ./scripts/build-speak-cli.sh <path-to-JustSpeakToIt.app> [signing-identity]
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

# Resolve before the cd below, so a relative app path keeps pointing at the
# bundle the caller meant.
APP_PATH="$(cd "$APP_PATH" && pwd -P)"

cd "$ROOT_DIR"
# The two slices are built separately and joined with lipo: a single swift
# build invocation passing both arch flags fails to plan the package graph
# ("duplicate key found: ID(moduleName: \"CommandLineTool\", packageIdentity:
# swiftformat)") because the SwiftFormat plugin dependency is modelled once
# per architecture (issue #759).
echo "==> Building speak (release, arm64)"
swift build --product speak --configuration release --arch arm64
echo "==> Building speak (release, x86_64)"
swift build --product speak --configuration release --arch x86_64

ARM64_BINARY="$(swift build --product speak --configuration release \
    --arch arm64 --show-bin-path)/speak"
X86_64_BINARY="$(swift build --product speak --configuration release \
    --arch x86_64 --show-bin-path)/speak"

for slice in "$ARM64_BINARY" "$X86_64_BINARY"; do
    if [[ ! -f "$slice" ]]; then
        echo "error: built binary missing at $slice" >&2
        exit 1
    fi
done

BINARY_PATH="$(mktemp -d)/speak"
echo "==> Creating universal binary"
lipo -create "$ARM64_BINARY" "$X86_64_BINARY" -output "$BINARY_PATH"

# Deterministic validation: the embedded CLI must contain both slices, so a
# regression back to a single-arch binary fails the release here, not on a
# user's machine.
UNIVERSAL_ARCHS="$(lipo -archs "$BINARY_PATH")"
for required_arch in arm64 x86_64; do
    if [[ " $UNIVERSAL_ARCHS " != *" $required_arch "* ]]; then
        echo "error: universal speak binary is missing $required_arch (got: $UNIVERSAL_ARCHS)" >&2
        exit 1
    fi
done
echo "==> Universal binary contains: $UNIVERSAL_ARCHS"

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

    # Copying into Contents/MacOS invalidates the bundle signature, so re-sign the
    # app itself last. The release workflow re-signs afterwards too; doing it here
    # keeps the script correct for standalone use.
    echo "==> Re-signing $APP_PATH after embedding"
    codesign --force --timestamp --options runtime \
        --sign "$SIGN_IDENTITY" \
        --entitlements "$ROOT_DIR/Config/SpeakMacOS.entitlements" \
        "$APP_PATH"
else
    echo "==> Skipping codesign (no identity supplied)"
fi

"$DESTINATION" --version
echo "==> speak embedded successfully"
