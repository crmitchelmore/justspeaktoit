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
echo "$PRIVATE_KEY_BASE64" | base64 --decode > "$PRIVATE_KEY_FILE"

# Find Sparkle's sign_update tool
SIGN_UPDATE=""
if [ -f ".build/artifacts/sparkle/Sparkle/bin/sign_update" ]; then
    SIGN_UPDATE=".build/artifacts/sparkle/Sparkle/bin/sign_update"
elif command -v sign_update &> /dev/null; then
    SIGN_UPDATE="sign_update"
else
    echo "Warning: sign_update not found, downloading Sparkle tools..."
    SPARKLE_VERSION="2.8.1"
    curl -sL "https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz" | tar xJ -C /tmp
    SIGN_UPDATE="/tmp/Sparkle.framework/Resources/bin/sign_update"
fi

# Generate EdDSA signature
SIGNATURE=$("$SIGN_UPDATE" --sign "$PRIVATE_KEY_FILE" "$DMG_PATH" | grep "sparkle:edSignature" | sed 's/.*sparkle:edSignature="\([^"]*\)".*/\1/')

# Clean up private key
rm -f "$PRIVATE_KEY_FILE"

if [ -z "$SIGNATURE" ]; then
    echo "Error: Failed to generate signature"
    exit 1
fi

# GitHub release download URL
DOWNLOAD_URL="https://github.com/crmitchelmore/justspeaktoit/releases/download/v${VERSION}/${DMG_NAME}"

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
