#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE_PATH="$ROOT_DIR/Just Speak to It.xcworkspace"

SCHEME="${SCHEME:-SpeakiOS}"
CONFIGURATION="${CONFIGURATION:-Release}"
EXPORT_METHOD="${EXPORT_METHOD:-development}" # development | ad-hoc | app-store

BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/build}"
ARCHIVE_PATH="${ARCHIVE_PATH:-$BUILD_DIR/$SCHEME.xcarchive}"
EXPORT_PATH="${EXPORT_PATH:-$BUILD_DIR/$SCHEME-export}"

mkdir -p "$BUILD_DIR"

if [[ ! -d "$WORKSPACE_PATH" ]]; then
    (cd "$ROOT_DIR" && tuist generate)
fi

EXPORT_OPTIONS_PLIST="$(mktemp -t exportOptions.XXXXXX.plist)"
trap 'rm -f "$EXPORT_OPTIONS_PLIST"' EXIT

cat >"$EXPORT_OPTIONS_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>$EXPORT_METHOD</string>
  <key>signingStyle</key>
  <string>automatic</string>
</dict>
</plist>
EOF

echo "==> Archiving ($SCHEME, $CONFIGURATION)"
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild \
  -workspace "$WORKSPACE_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE_PATH" \
  -allowProvisioningUpdates \
  archive

echo "==> Exporting IPA ($EXPORT_METHOD)"
rm -rf "$EXPORT_PATH"
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS_PLIST" \
  -allowProvisioningUpdates

echo "==> Done"
echo "Archive: $ARCHIVE_PATH"
echo "Export:  $EXPORT_PATH"
ls -1 "$EXPORT_PATH" | sed 's/^/  - /'
