#!/bin/bash
# Bump version for release
# Usage: ./scripts/bump-version.sh [major|minor|patch] or ./scripts/bump-version.sh 1.0.0

set -e

VERSION_FILE="VERSION"
PLIST_FILE="Config/AppInfo.plist"

# Read current version
CURRENT_VERSION=$(cat "$VERSION_FILE")
echo "Current version: $CURRENT_VERSION"

# Parse version
IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT_VERSION"

# Determine new version
case "$1" in
  major)
    MAJOR=$((MAJOR + 1))
    MINOR=0
    PATCH=0
    ;;
  minor)
    MINOR=$((MINOR + 1))
    PATCH=0
    ;;
  patch)
    PATCH=$((PATCH + 1))
    ;;
  *)
    if [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      NEW_VERSION="$1"
    else
      echo "Usage: $0 [major|minor|patch|X.Y.Z]"
      exit 1
    fi
    ;;
esac

# Set new version
NEW_VERSION="${NEW_VERSION:-$MAJOR.$MINOR.$PATCH}"
echo "New version: $NEW_VERSION"

# Update VERSION file
echo "$NEW_VERSION" > "$VERSION_FILE"

# Update Info.plist
sed -i '' "s/<string>$CURRENT_VERSION<\/string>/<string>$NEW_VERSION<\/string>/" "$PLIST_FILE"

# Increment build number in plist
BUILD_NUM=$(grep -A1 'CFBundleVersion' "$PLIST_FILE" | grep -o '[0-9]*')
NEW_BUILD=$((BUILD_NUM + 1))
sed -i '' "s/<key>CFBundleVersion<\/key>.*<string>[0-9]*<\/string>/<key>CFBundleVersion<\/key>\n\t<string>$NEW_BUILD<\/string>/" "$PLIST_FILE"

echo "✓ Updated VERSION to $NEW_VERSION"
echo "✓ Updated CFBundleShortVersionString to $NEW_VERSION"
echo "✓ Updated CFBundleVersion to $NEW_BUILD"
echo ""
echo "Don't forget to:"
echo "  git add VERSION Config/AppInfo.plist"
echo "  git commit -m 'chore: bump version to $NEW_VERSION'"
echo "  git tag mac-v$NEW_VERSION"
