#!/usr/bin/env bash
# Sign a file with the Sparkle EdDSA (Ed25519) private key and print the
# base64 signature: the same signature sign_update writes into an appcast's
# sparkle:edSignature, so anything holding the app's SUPublicEDKey can verify
# it. Used for the speak CLI release manifest (issue #775).
#
# Usage: ./scripts/sparkle-sign-file.sh <private-key-base64> <file>

set -euo pipefail

PRIVATE_KEY_BASE64="${1:-}"
FILE="${2:-}"

if [[ -z "$PRIVATE_KEY_BASE64" || -z "$FILE" ]]; then
    echo "Usage: $0 <private-key-base64> <file>" >&2
    exit 1
fi
if [[ ! -f "$FILE" ]]; then
    echo "error: file not found: $FILE" >&2
    exit 1
fi

# sign_update reads the raw base64 string from the key file, not decoded bytes
# (the same convention as generate-appcast.sh).
PRIVATE_KEY_FILE="$(mktemp)"
trap 'rm -f "$PRIVATE_KEY_FILE"' EXIT
echo "$PRIVATE_KEY_BASE64" > "$PRIVATE_KEY_FILE"

# Only a sign_update that arrived through the package graph (SwiftPM's
# checksum-verified Sparkle artifact bundle) or is already installed may run
# with the private key on disk. There is deliberately no download fallback:
# a fetched binary would execute with access to the signing key.
SIGN_UPDATE=""
if [[ -f ".build/artifacts/sparkle/Sparkle/bin/sign_update" ]]; then
    SIGN_UPDATE=".build/artifacts/sparkle/Sparkle/bin/sign_update"
elif command -v sign_update &> /dev/null; then
    SIGN_UPDATE="sign_update"
else
    echo "error: sign_update not found; run 'swift package resolve' so SwiftPM fetches Sparkle's artifact bundle" >&2
    exit 1
fi

OUTPUT="$("$SIGN_UPDATE" --ed-key-file "$PRIVATE_KEY_FILE" "$FILE")"
SIGNATURE="$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' <<< "$OUTPUT" | head -n 1)"
if [[ -z "$SIGNATURE" ]]; then
    echo "error: sign_update produced no signature for $FILE" >&2
    echo "$OUTPUT" >&2
    exit 1
fi

printf '%s\n' "$SIGNATURE"
