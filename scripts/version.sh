#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="$ROOT_DIR/VERSION"
BUILD_FILE="$ROOT_DIR/BUILD"
PLIST_PATH="$ROOT_DIR/Config/AppInfo.plist"

function usage() {
    cat <<USAGE
Usage: $0 <command> [options]

Commands:
  bump-version [major|minor|patch]  Increment semantic version and reset build to 1.
  bump-build                        Increment build number only.
  show                              Print the current version and build numbers.
USAGE
}

function read_version() {
    if [[ ! -f "$VERSION_FILE" ]]; then
        echo "0.1.0"
        return
    fi
    tr -d '\n' <"$VERSION_FILE"
}

function read_build() {
    if [[ ! -f "$BUILD_FILE" ]]; then
        echo "1"
        return
    fi
    tr -d '\n' <"$BUILD_FILE"
}

function write_version() {
    printf '%s' "$1" >"$VERSION_FILE"
}

function write_build() {
    printf '%s' "$1" >"$BUILD_FILE"
}

function update_plist() {
    local version="$1"
    local build="$2"
    if [[ -f "$PLIST_PATH" ]]; then
        /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$PLIST_PATH" >/dev/null
        /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build" "$PLIST_PATH" >/dev/null
    else
        echo "Info: skipping Info.plist update ($PLIST_PATH not found)." >&2
    fi
}

function bump_version() {
    local level="${1:-patch}"
    local version
    version="$(read_version)"
    IFS='.' read -r major minor patch <<<"$version"
    case "$level" in
        major)
            major=$((major + 1))
            minor=0
            patch=0
            ;;
        minor)
            minor=$((minor + 1))
            patch=0
            ;;
        patch)
            patch=$((patch + 1))
            ;;
        *)
            echo "Unknown level '$level'." >&2
            exit 1
            ;;
    esac
    local next_version="${major}.${minor}.${patch}"
    write_version "$next_version"
    write_build "1"
    update_plist "$next_version" "1"
    echo "Version bumped to $next_version (build 1)"
}

function bump_build() {
    local build
    build="$(read_build)"
    build=$((build + 1))
    write_build "$build"
    update_plist "$(read_version)" "$build"
    echo "Build bumped to $build"
}

function show_version() {
    echo "Version: $(read_version)"
    echo "Build: $(read_build)"
}

command="${1:-}"
case "$command" in
    bump-version)
        bump_version "${2:-patch}"
        ;;
    bump-build)
        bump_build
        ;;
    show)
        show_version
        ;;
    ""|-h|--help)
        usage
        ;;
    *)
        echo "Unknown command '$command'." >&2
        usage
        exit 1
        ;;
 esac
