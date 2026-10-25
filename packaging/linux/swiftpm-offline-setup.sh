#!/bin/sh
# Prepares an offline SwiftPM build of the Linux graph (used by the Flatpak
# manifest; usable in any build tree whose dependencies are already checked out).
#
#   packaging/linux/swiftpm-offline-setup.sh [deps-dir]
#
# 1. Replaces the Apple-graph Package.resolved with packaging/linux/Package.resolved.
# 2. Points a SwiftPM mirror for every pin at <deps-dir>/<identity> (default
#    ./swiftpm-deps, where swiftpm-sources.json checks them out), so SwiftPM
#    clones local repositories instead of GitHub.
# Build afterwards with --force-resolved-versions so SwiftPM never re-resolves.
set -eu

deps="${1:-$PWD/swiftpm-deps}"
case "$deps" in /*) ;; *) deps="$PWD/$deps" ;; esac
resolved=packaging/linux/Package.resolved
[ -f Package.swift ] && [ -f "$resolved" ] || { echo "run from the repository root" >&2; exit 1; }

cp "$resolved" Package.resolved

# identity<TAB>location for every pin, without needing python or jq.
pins=$(sed -n -e 's/^ *"identity" : "\(.*\)",$/\1/p' -e 's/^ *"location" : "\(.*\)",$/\1/p' "$resolved" | paste - -)
[ -n "$pins" ] || { echo "no pins in $resolved" >&2; exit 1; }

echo "$pins" | while IFS="$(printf '\t')" read -r identity location; do
    checkout="$deps/$identity"
    [ -d "$checkout/.git" ] || [ -f "$checkout/.git" ] || {
        echo "missing checkout for $identity at $checkout" >&2
        exit 1
    }
    swift package config set-mirror --original "$location" --mirror "$checkout"
    echo "mirror: $location -> $checkout"
done
