#!/usr/bin/env bash
# Build the `speak` automation CLI and embed it inside JustSpeakToIt.app.
#
# Usage: ./scripts/build-speak-cli.sh <path-to-JustSpeakToIt.app> [signing-identity] [arm64|universal]
#
# The CLI is a thin client for the automation socket the app exposes, so it must
# ship with the app rather than as an independent download: the Homebrew cask
# links `Contents/MacOS/speak` onto the user's PATH.
#
# The embedded CLI always matches the app's own slices (issue #774): the arm64
# primary download embeds an arm64-only CLI and the universal legacy download
# embeds a universal one. The default is universal.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${1:-}"
SIGN_IDENTITY="${2:-}"
VARIANT="${3:-universal}"

if [[ -z "$APP_PATH" ]]; then
    echo "Usage: $0 <path-to-JustSpeakToIt.app> [signing-identity] [arm64|universal]" >&2
    exit 1
fi

if [[ ! -d "$APP_PATH" ]]; then
    echo "error: app bundle not found at $APP_PATH" >&2
    exit 1
fi

case "$VARIANT" in
    arm64) REQUIRED_ARCHS="arm64" ;;
    universal) REQUIRED_ARCHS="arm64 x86_64" ;;
    *)
        echo "error: unknown variant '$VARIANT' (expected arm64 or universal)" >&2
        exit 1
        ;;
esac

# Resolve before the cd below, so a relative app path keeps pointing at the
# bundle the caller meant.
APP_PATH="$(cd "$APP_PATH" && pwd -P)"

cd "$ROOT_DIR"
# The slices are built separately and joined with lipo: a single swift build
# invocation passing both arch flags fails to plan the package graph
# ("duplicate key found: ID(moduleName: \"CommandLineTool\", packageIdentity:
# swiftformat)") because the SwiftFormat plugin dependency is modelled once
# per architecture (issue #759).
echo "==> Building speak (release, arm64)"
swift build --product speak --configuration release --arch arm64
ARM64_BINARY="$(swift build --product speak --configuration release \
    --arch arm64 --show-bin-path)/speak"

BINARY_PATH="$(mktemp -d)/speak"
if [[ "$VARIANT" == "universal" ]]; then
    echo "==> Building speak (release, x86_64)"
    swift build --product speak --configuration release --arch x86_64
    X86_64_BINARY="$(swift build --product speak --configuration release \
        --arch x86_64 --show-bin-path)/speak"

    for slice in "$ARM64_BINARY" "$X86_64_BINARY"; do
        if [[ ! -f "$slice" ]]; then
            echo "error: built binary missing at $slice" >&2
            exit 1
        fi
    done

    echo "==> Creating universal binary"
    lipo -create "$ARM64_BINARY" "$X86_64_BINARY" -output "$BINARY_PATH"
else
    if [[ ! -f "$ARM64_BINARY" ]]; then
        echo "error: built binary missing at $ARM64_BINARY" >&2
        exit 1
    fi
    cp "$ARM64_BINARY" "$BINARY_PATH"
fi

# Deterministic validation: the embedded CLI must contain exactly the slices
# its variant promises, so a regression (a single-arch universal binary, or an
# x86_64 slice leaking into the arm64 download) fails the release here, not on
# a user's machine.
EMBEDDED_ARCHS="$(lipo -archs "$BINARY_PATH")"
for required_arch in $REQUIRED_ARCHS; do
    if [[ " $EMBEDDED_ARCHS " != *" $required_arch "* ]]; then
        echo "error: $VARIANT speak binary is missing $required_arch (got: $EMBEDDED_ARCHS)" >&2
        exit 1
    fi
done
for present_arch in $EMBEDDED_ARCHS; do
    if [[ " $REQUIRED_ARCHS " != *" $present_arch "* ]]; then
        echo "error: $VARIANT speak binary must not contain $present_arch (got: $EMBEDDED_ARCHS)" >&2
        exit 1
    fi
done
echo "==> $VARIANT binary contains: $EMBEDDED_ARCHS"

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
