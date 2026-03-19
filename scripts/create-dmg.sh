#!/bin/bash
# Creates a beautiful DMG installer with background and icon layout
# Usage: ./scripts/create-dmg.sh <app_path> <output_dmg> <version>

set -e

APP_PATH="$1"
OUTPUT_DMG="$2"
VERSION="$3"
VOLUME_NAME="Just Speak to It"
DMG_TEMP="$RUNNER_TEMP/dmg_temp"
DMG_TEMP_RW="$RUNNER_TEMP/dmg_temp_rw.dmg"
MOUNT_DEVICE=""
MOUNT_DIR=""

if [ -z "$APP_PATH" ] || [ -z "$OUTPUT_DMG" ]; then
    echo "Usage: $0 <app_path> <output_dmg> [version]"
    exit 1
fi

# Use RUNNER_TEMP if set (CI), otherwise use /tmp
if [ -z "$RUNNER_TEMP" ]; then
    RUNNER_TEMP="/tmp"
fi

DMG_TEMP="$RUNNER_TEMP/dmg_temp"
DMG_TEMP_RW="$RUNNER_TEMP/dmg_temp_rw.dmg"

detach_mounted_dmg() {
    local attempt

    for attempt in 1 2 3 4 5; do
        if [ -n "$MOUNT_DEVICE" ] && hdiutil detach "$MOUNT_DEVICE" -force >/dev/null 2>&1; then
            MOUNT_DEVICE=""
            MOUNT_DIR=""
            return 0
        fi

        if [ -n "$MOUNT_DIR" ] && hdiutil detach "$MOUNT_DIR" -force >/dev/null 2>&1; then
            MOUNT_DEVICE=""
            MOUNT_DIR=""
            return 0
        fi

        if [ -n "$MOUNT_DEVICE" ] && diskutil eject "$MOUNT_DEVICE" >/dev/null 2>&1; then
            MOUNT_DEVICE=""
            MOUNT_DIR=""
            return 0
        fi

        echo "  Detach attempt $attempt failed; waiting for Finder to release the DMG..."
        sync
        sleep 2
    done

    echo "Failed to detach DMG mounted at ${MOUNT_DIR:-unknown}"
    return 1
}

cleanup_mounted_dmg() {
    if [ -n "$MOUNT_DEVICE" ] || [ -n "$MOUNT_DIR" ]; then
        echo "  Cleaning up mounted DMG..."
        detach_mounted_dmg || true
    fi
}

trap cleanup_mounted_dmg EXIT

echo "Creating DMG installer..."
echo "  App: $APP_PATH"
echo "  Output: $OUTPUT_DMG"

# Clean up any previous runs
rm -rf "$DMG_TEMP"
rm -f "$DMG_TEMP_RW"
rm -f "$OUTPUT_DMG"

# Create temp directory structure
mkdir -p "$DMG_TEMP/.background"

# Copy app
cp -R "$APP_PATH" "$DMG_TEMP/"

# Copy background image
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
if [ -f "$PROJECT_DIR/Resources/dmg-background@2x.png" ]; then
    cp "$PROJECT_DIR/Resources/dmg-background@2x.png" "$DMG_TEMP/.background/background.png"
    echo "  Using custom background"
fi

# Create Applications symlink
ln -s /Applications "$DMG_TEMP/Applications"

# Calculate size (app size + 20MB buffer)
APP_SIZE=$(du -sm "$APP_PATH" | cut -f1)
DMG_SIZE=$((APP_SIZE + 20))

# Create temporary writable DMG
hdiutil create -srcfolder "$DMG_TEMP" -volname "$VOLUME_NAME" -fs HFS+ \
    -fsargs "-c c=64,a=16,e=16" -format UDRW -size "${DMG_SIZE}m" "$DMG_TEMP_RW"

# Mount the DMG
ATTACH_OUTPUT=$(hdiutil attach -readwrite -noverify "$DMG_TEMP_RW")
MOUNT_DEVICE=$(printf '%s\n' "$ATTACH_OUTPUT" | awk '/\/Volumes\// {print $1; exit}')
MOUNT_DIR=$(printf '%s\n' "$ATTACH_OUTPUT" | awk -F '\t' '/\/Volumes\// {print $NF; exit}')

if [ -z "$MOUNT_DEVICE" ] || [ -z "$MOUNT_DIR" ]; then
    echo "Failed to determine mounted DMG details"
    exit 1
fi

echo "  Mounted at: $MOUNT_DIR"

# Wait for mount
sleep 2

# Set up the Finder view using AppleScript
echo "  Configuring Finder view..."
osascript <<EOF
tell application "Finder"
    tell disk "$VOLUME_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        -- Window size matches background: 660x520
        set the bounds of container window to {100, 100, 760, 620}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 100
        set text size of viewOptions to 14
        
        -- Set background
        try
            set background picture of viewOptions to file ".background:background.png"
        end try
        
        -- Position icons (centered in the layout)
        set position of item "JustSpeakToIt.app" of container window to {145, 220}
        set position of item "Applications" of container window to {515, 220}
        
        close
        open
        update without registering applications
        delay 2
    end tell
end tell
EOF

# Sync and wait
sync
sleep 3

# Unmount
detach_mounted_dmg

# Convert to compressed read-only DMG
hdiutil convert "$DMG_TEMP_RW" -format UDZO -imagekey zlib-level=9 -o "$OUTPUT_DMG"

# Clean up
rm -rf "$DMG_TEMP"
rm -f "$DMG_TEMP_RW"
trap - EXIT

echo "✅ DMG created: $OUTPUT_DMG"
echo "   Size: $(du -h "$OUTPUT_DMG" | cut -f1)"
