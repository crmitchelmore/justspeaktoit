#!/usr/bin/env bash
# Fail if a release artefact can honour the native-CI Keychain redirect (#1360).
#
# Usage: ./scripts/verify-no-test-keychain-redirect.sh <app-bundle|executable|directory|archive.zip>...
#
# KeychainAccess reads these environment names only when SpeakCore is compiled
# with JSTI_TEST_KEYCHAIN_REDIRECT, which CI test commands set and distribution
# builds must not. Every Mach-O file under each path is scanned, including the
# main executable, an embedded `speak` CLI and embedded frameworks; `.zip`
# archives (the standalone CLI assets) are expanded and scanned the same way.

set -euo pipefail

if [[ $# -eq 0 ]]; then
    echo "Usage: $0 <app-bundle|executable|directory|archive.zip>..." >&2
    exit 1
fi

FORBIDDEN=(JSTI_TEST_KEYCHAIN_PATH JSTI_TEST_KEYCHAIN_PASSWORD RUNNER_ENVIRONMENT)
scanned=0
failed=0
expanded="$(mktemp -d)"
trap 'rm -rf "$expanded"' EXIT

is_macho() {
    local magic
    magic="$(LC_ALL=C od -An -N4 -tx1 "$1" 2>/dev/null | tr -d ' \n')"
    case "$magic" in
        feedface|feedfacf|cefaedfe|cffaedfe|cafebabe|bebafeca) return 0 ;;
        *) return 1 ;;
    esac
}

for root in "$@"; do
    if [[ ! -e "$root" ]]; then
        echo "error: $root does not exist" >&2
        exit 1
    fi
    scan="$root"
    if [[ -f "$root" && "$root" == *.zip ]]; then
        scan="$expanded/$(basename "$root")"
        mkdir -p "$scan"
        ditto -x -k "$root" "$scan"
    fi
    while IFS= read -r -d '' file; do
        is_macho "$file" || continue
        scanned=$((scanned + 1))
        found="$(strings -a "$file" | grep -oF -e "${FORBIDDEN[0]}" -e "${FORBIDDEN[1]}" -e "${FORBIDDEN[2]}" \
            | sort -u | tr '\n' ' ' || true)"
        if [[ -n "$found" ]]; then
            echo "::error::$file contains test Keychain redirect strings: $found"
            failed=1
        fi
    done < <(find "$scan" -type f -print0)
done

if [[ "$scanned" -eq 0 ]]; then
    echo "error: no Mach-O files found in: $*" >&2
    exit 1
fi
if [[ "$failed" -ne 0 ]]; then
    echo "Release artefacts were built with JSTI_TEST_KEYCHAIN_REDIRECT; rebuild without it." >&2
    exit 1
fi
echo "No test Keychain redirect strings in $scanned Mach-O file(s)."
