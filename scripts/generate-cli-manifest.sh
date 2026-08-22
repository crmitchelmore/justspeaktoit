#!/usr/bin/env bash
# Write the speak CLI release manifest the app's installer reads
# (SpeakCLIManifest, issue #775), and sign it with the Sparkle key when one is
# supplied so the app can verify it with the SUPublicEDKey it already ships.
#
# Usage: ./scripts/generate-cli-manifest.sh <version> <automation-schema-version> <output-dir> <zip>...
#
# Environment:
#   SPARKLE_PRIVATE_KEY  base64 Ed25519 private key; when set, writes
#                        speak-cli-manifest.json.sig next to the manifest.
#
# Each <zip> must be named speak-<version>-<arch>.zip (as produced by
# build-speak-cli-standalone.sh); its release URL, byte count and SHA-256 are
# recorded. The manifest bytes are what the signature covers, so the file is
# written once and never reformatted afterwards.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-}"
SCHEMA_VERSION="${2:-}"
OUTPUT_DIR="${3:-}"
shift 3 2>/dev/null || true

if [[ -z "$VERSION" || -z "$SCHEMA_VERSION" || -z "$OUTPUT_DIR" || $# -eq 0 ]]; then
    echo "Usage: $0 <version> <automation-schema-version> <output-dir> <zip>..." >&2
    exit 1
fi
if [[ ! "$SCHEMA_VERSION" =~ ^[0-9]+$ ]]; then
    echo "error: automation schema version '$SCHEMA_VERSION' is not a number" >&2
    exit 1
fi

RELEASE_URL="https://github.com/crmitchelmore/justspeaktoit/releases/download/mac-v${VERSION}"
MANIFEST_SCHEMA_VERSION=1

mkdir -p "$OUTPUT_DIR"
MANIFEST_PATH="$OUTPUT_DIR/speak-cli-manifest.json"
SIGNATURE_PATH="$MANIFEST_PATH.sig"

ASSETS=""
SEEN_ARCHS=""
for archive in "$@"; do
    if [[ ! -f "$archive" ]]; then
        echo "error: archive not found: $archive" >&2
        exit 1
    fi
    name="$(basename "$archive")"
    prefix="speak-${VERSION}-"
    if [[ "$name" != "$prefix"*.zip ]]; then
        echo "error: $name is not named speak-${VERSION}-<arch>.zip" >&2
        exit 1
    fi
    arch="${name#"$prefix"}"
    arch="${arch%.zip}"
    case "$arch" in
        arm64|x86_64) ;;
        *)
            echo "error: unsupported architecture '$arch' in $name" >&2
            exit 1
            ;;
    esac
    if [[ " $SEEN_ARCHS " == *" $arch "* ]]; then
        echo "error: more than one archive for $arch" >&2
        exit 1
    fi
    SEEN_ARCHS="$SEEN_ARCHS $arch"

    byte_count="$(stat -f%z "$archive")"
    sha256="$(shasum -a 256 "$archive" | awk '{print $1}')"
    asset="$(printf '    {"architecture": "%s", "url": "%s/%s", "byteCount": %s, "sha256": "%s"}' \
        "$arch" "$RELEASE_URL" "$name" "$byte_count" "$sha256")"
    if [[ -n "$ASSETS" ]]; then
        ASSETS="$ASSETS,"$'\n'"$asset"
    else
        ASSETS="$asset"
    fi
    echo "==> $name: $byte_count bytes, sha256 $sha256" >&2
done

cat > "$MANIFEST_PATH" << EOF
{
  "schemaVersion": ${MANIFEST_SCHEMA_VERSION},
  "version": "${VERSION}",
  "automationSchemaVersion": ${SCHEMA_VERSION},
  "assets": [
${ASSETS}
  ]
}
EOF
echo "==> Wrote $MANIFEST_PATH" >&2

rm -f "$SIGNATURE_PATH"
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
    "$ROOT_DIR/scripts/sparkle-sign-file.sh" "$SPARKLE_PRIVATE_KEY" "$MANIFEST_PATH" > "$SIGNATURE_PATH"
    echo "==> Wrote $SIGNATURE_PATH" >&2
else
    echo "==> SPARKLE_PRIVATE_KEY not set; manifest left unsigned" >&2
fi

echo "$MANIFEST_PATH"
