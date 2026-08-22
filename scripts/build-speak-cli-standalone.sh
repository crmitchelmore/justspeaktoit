#!/usr/bin/env bash
# Build the standalone `speak` CLI for one architecture and package it as the
# release asset the in-app installer and the Homebrew formula consume
# (issue #775).
#
# Usage: ./scripts/build-speak-cli-standalone.sh <arm64|x86_64> <version> <output-dir> [signing-identity]
#
# Produces <output-dir>/speak-<version>-<arch>.zip holding a single `speak`
# executable at the archive root, built for exactly that architecture, with the
# release version linked into a `__TEXT,__speak_ver` section so the binary
# describes itself without an app bundle around it (SpeakCLIVersion). With a
# signing identity the executable is signed with the hardened runtime; the
# caller notarises the archive.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCH="${1:-}"
VERSION="${2:-}"
OUTPUT_DIR="${3:-}"
SIGN_IDENTITY="${4:-}"

usage() {
    echo "Usage: $0 <arm64|x86_64> <version> <output-dir> [signing-identity]" >&2
    exit 1
}

[[ -n "$ARCH" && -n "$VERSION" && -n "$OUTPUT_DIR" ]] || usage

case "$ARCH" in
    arm64|x86_64) ;;
    *)
        echo "error: unknown architecture '$ARCH' (expected arm64 or x86_64)" >&2
        exit 1
        ;;
esac

# The same shape SpeakCLIVersion.parseEmbeddedVersion accepts.
if [[ ! "$VERSION" =~ ^[A-Za-z0-9.+-]{1,64}$ ]]; then
    echo "error: version '$VERSION' is not a plain version string" >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd -P)"
ARCHIVE_PATH="$OUTPUT_DIR/speak-${VERSION}-${ARCH}.zip"

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
VERSION_FILE="$SCRATCH/speak_ver"
printf '%s' "$VERSION" > "$VERSION_FILE"

cd "$ROOT_DIR"
# Each slice is built on its own, as build-speak-cli.sh does (issue #759); the
# linker flags create the version section in this product's executable only.
echo "==> Building speak (release, $ARCH, version $VERSION)"
swift build --product speak --configuration release --arch "$ARCH" \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __speak_ver -Xlinker "$VERSION_FILE"
BUILT_BINARY="$(swift build --product speak --configuration release --arch "$ARCH" \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __speak_ver -Xlinker "$VERSION_FILE" \
    --show-bin-path)/speak"
if [[ ! -f "$BUILT_BINARY" ]]; then
    echo "error: built binary missing at $BUILT_BINARY" >&2
    exit 1
fi

STAGE="$SCRATCH/stage"
mkdir -p "$STAGE"
BINARY="$STAGE/speak"
cp "$BUILT_BINARY" "$BINARY"
chmod 755 "$BINARY"

# Exactly one slice: the installer refuses anything else, so fail here instead.
BUILT_ARCHS="$(lipo -archs "$BINARY")"
if [[ "$BUILT_ARCHS" != "$ARCH" ]]; then
    echo "error: built binary contains [$BUILT_ARCHS] but must contain exactly [$ARCH]" >&2
    exit 1
fi

# The version section must read back as the version, byte for byte.
EMBEDDED_VERSION="$(xcrun segedit "$BINARY" -extract __TEXT __speak_ver "$SCRATCH/extracted" \
    && tr -d '\0' < "$SCRATCH/extracted")"
if [[ "$EMBEDDED_VERSION" != "$VERSION" ]]; then
    echo "error: __TEXT,__speak_ver reads '$EMBEDDED_VERSION', expected '$VERSION'" >&2
    exit 1
fi
echo "==> Linked version section: $EMBEDDED_VERSION"

if [[ -n "$SIGN_IDENTITY" ]]; then
    echo "==> Signing with '$SIGN_IDENTITY' (hardened runtime)"
    codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$BINARY"
    codesign --verify --strict --verbose=2 "$BINARY"
    codesign -dv --verbose=4 "$BINARY" 2>&1 | grep -q "runtime"
    echo "==> Hardened runtime confirmed"
else
    echo "==> Skipping codesign (no identity supplied)"
fi

# A native slice must run and report the linked version; x86_64 runs through
# Rosetta where it is installed and is otherwise verified by its section only.
can_run=false
if [[ "$ARCH" == "$(uname -m)" ]]; then
    can_run=true
elif [[ "$ARCH" == "x86_64" ]] && arch -x86_64 /usr/bin/true 2>/dev/null; then
    can_run=true
fi
if [[ "$can_run" == true ]]; then
    REPORTED="$("$BINARY" --version)"
    if [[ "$REPORTED" != "speak $VERSION" ]]; then
        echo "error: 'speak --version' printed '$REPORTED', expected 'speak $VERSION'" >&2
        exit 1
    fi
    echo "==> $REPORTED"
else
    echo "==> $ARCH cannot run on this machine; skipped the --version check"
fi

# Archive the executable at the root, the way the app extracts it
# (ditto -x -k <archive> <dir> must yield <dir>/speak) and Homebrew installs it.
rm -f "$ARCHIVE_PATH"
ditto -c -k --norsrc --noextattr --noqtn "$STAGE" "$ARCHIVE_PATH"

CHECK="$SCRATCH/check"
mkdir -p "$CHECK"
ditto -x -k "$ARCHIVE_PATH" "$CHECK"
ENTRIES="$(find "$CHECK" -mindepth 1 -maxdepth 1 -exec basename {} \; | sort | tr '\n' ' ' | sed 's/ $//')"
if [[ "$ENTRIES" != "speak" ]]; then
    echo "error: archive root must contain only 'speak' (found: $ENTRIES)" >&2
    exit 1
fi
if ! cmp -s "$BINARY" "$CHECK/speak"; then
    echo "error: archive round trip altered the executable" >&2
    exit 1
fi

bytes() { stat -f%z "$1"; }
megabytes() { awk -v b="$1" 'BEGIN { printf "%.1f", b / 1048576 }'; }
ARCHIVE_BYTES="$(bytes "$ARCHIVE_PATH")"
BINARY_BYTES="$(bytes "$BINARY")"
echo "==> $(basename "$ARCHIVE_PATH"): $(megabytes "$ARCHIVE_BYTES") MB compressed," \
    "$(megabytes "$BINARY_BYTES") MB installed"

# One Markdown row per asset; the workflow writes the table header.
ROW="| $ARCH | $(megabytes "$ARCHIVE_BYTES") MB | $(megabytes "$BINARY_BYTES") MB | $VERSION |"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    echo "$ROW" >> "$GITHUB_STEP_SUMMARY"
fi

echo "$ARCHIVE_PATH"
