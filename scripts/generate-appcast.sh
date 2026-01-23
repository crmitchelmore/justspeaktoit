#!/bin/bash
# Generate Sparkle appcast.xml from GitHub release
# Usage: ./scripts/generate-appcast.sh <version> <dmg-path> <private-key-base64>

set -e

VERSION="$1"
DMG_PATH="$2"
PRIVATE_KEY_BASE64="$3"

if [ -z "$VERSION" ] || [ -z "$DMG_PATH" ] || [ -z "$PRIVATE_KEY_BASE64" ]; then
    echo "Usage: $0 <version> <dmg-path> <private-key-base64>"
    exit 1
fi

# Get file info
FILE_SIZE=$(stat -f%z "$DMG_PATH" 2>/dev/null || stat --format=%s "$DMG_PATH")
PUB_DATE=$(date -R)
DMG_NAME=$(basename "$DMG_PATH")

# Create temp file for private key
PRIVATE_KEY_FILE=$(mktemp)
# Ensure private key is cleaned up on exit (success or failure)
trap 'rm -f "$PRIVATE_KEY_FILE"' EXIT

# The Sparkle private key is a base64-encoded string (44 chars)
# sign_update expects the raw string, NOT base64-decoded bytes
echo "$PRIVATE_KEY_BASE64" > "$PRIVATE_KEY_FILE"
echo "Private key written (raw, not decoded)" >&2

# Find Sparkle's sign_update tool
SIGN_UPDATE=""
if [ -f ".build/artifacts/sparkle/Sparkle/bin/sign_update" ]; then
    SIGN_UPDATE=".build/artifacts/sparkle/Sparkle/bin/sign_update"
elif command -v sign_update &> /dev/null; then
    SIGN_UPDATE="sign_update"
else
    echo "Warning: sign_update not found, downloading Sparkle tools..." >&2
    SPARKLE_VERSION="2.8.1"
    curl -sL "https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz" | tar xJ -C /tmp
    SIGN_UPDATE="/tmp/bin/sign_update"
fi

# Generate EdDSA signature
# For newer Sparkle keys, use --ed-key-file with stdin (-) as recommended
# sign_update outputs the signature attributes that need to be extracted
echo "Running sign_update..." >&2
echo "SIGN_UPDATE path: $SIGN_UPDATE" >&2
echo "DMG_PATH: $DMG_PATH" >&2
ls -la "$SIGN_UPDATE" >&2 || echo "sign_update not found" >&2

# Run sign_update and capture output
set +e
"$SIGN_UPDATE" --ed-key-file "$PRIVATE_KEY_FILE" "$DMG_PATH" > /tmp/sign_output.txt 2>&1
SIGN_EXIT_CODE=$?
set -e

echo "sign_update exit code: $SIGN_EXIT_CODE" >&2
echo "sign_update output:" >&2
cat /tmp/sign_output.txt >&2

SIGNATURE=$(grep "sparkle:edSignature" /tmp/sign_output.txt | sed 's/.*sparkle:edSignature="\([^"]*\)".*/\1/' || true)

if [ -z "$SIGNATURE" ]; then
    echo "Error: Failed to generate signature" >&2
    exit 1
fi

# GitHub release download URL
DOWNLOAD_URL="https://github.com/crmitchelmore/justspeaktoit/releases/download/v${VERSION}/${DMG_NAME}"

# Generate release notes from git commits since last tag
LAST_TAG=$(git describe --tags --abbrev=0 HEAD^ 2>/dev/null || echo "")
if [ -n "$LAST_TAG" ]; then
    echo "Generating release notes from commits since $LAST_TAG" >&2
    RELEASE_NOTES=$(git log $LAST_TAG..HEAD --pretty=format:"<li>%s</li>" --grep="^feat\|^fix\|^perf" --extended-regexp 2>/dev/null | head -20 || echo "<li>Bug fixes and improvements</li>")
else
    RELEASE_NOTES="<li>Initial release</li>"
fi

# If no meaningful commits found, use a default
if [ -z "$RELEASE_NOTES" ]; then
    RELEASE_NOTES="<li>Bug fixes and improvements</li>"
fi

# Generate appcast XML
cat << EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Just Speak to It Updates</title>
    <link>https://justspeaktoit.com/appcast.xml</link>
    <description>Most recent updates to Just Speak to It</description>
    <language>en</language>
    <item>
      <title>Version ${VERSION}</title>
      <sparkle:version>${VERSION}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <pubDate>${PUB_DATE}</pubDate>
      <description><![CDATA[
        <h2>What's New in ${VERSION}</h2>
        <ul>
          ${RELEASE_NOTES}
        </ul>
      ]]></description>
      <enclosure
        url="${DOWNLOAD_URL}"
        sparkle:edSignature="${SIGNATURE}"
        length="${FILE_SIZE}"
        type="application/octet-stream"/>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
    </item>
  </channel>
</rss>
EOF
