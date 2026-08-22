#!/usr/bin/env bash
# Verify a standalone speak CLI release archive the way the app's installer
# will (issue #775): a single `speak` at the archive root, exactly the promised
# architecture, the release version linked in, a Developer ID signature with
# the hardened runtime that satisfies the installer's requirement, and — once
# notarised — Gatekeeper acceptance.
#
# Usage: ./scripts/verify-speak-cli.sh <zip> <arm64|x86_64> <version> [--signed] [--notarised]
#
#   --signed     fail unless the executable carries a Developer ID signature
#   --notarised  also require Gatekeeper to accept the executable (implies --signed)

set -euo pipefail

ARCHIVE="${1:-}"
ARCH="${2:-}"
VERSION="${3:-}"
shift 3 2>/dev/null || true
REQUIRE_SIGNED=false
REQUIRE_NOTARISED=false
for flag in "$@"; do
    case "$flag" in
        --signed) REQUIRE_SIGNED=true ;;
        --notarised) REQUIRE_SIGNED=true; REQUIRE_NOTARISED=true ;;
        *)
            echo "error: unknown option '$flag'" >&2
            exit 1
            ;;
    esac
done

if [[ -z "$ARCHIVE" || -z "$ARCH" || -z "$VERSION" ]]; then
    echo "Usage: $0 <zip> <arm64|x86_64> <version> [--signed] [--notarised]" >&2
    exit 1
fi
if [[ ! -f "$ARCHIVE" ]]; then
    echo "error: archive not found: $ARCHIVE" >&2
    exit 1
fi

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

ditto -x -k "$ARCHIVE" "$SCRATCH/extract"
ENTRIES="$(find "$SCRATCH/extract" -mindepth 1 -maxdepth 1 -exec basename {} \; | sort | tr '\n' ' ' | sed 's/ $//')"
if [[ "$ENTRIES" != "speak" ]]; then
    echo "error: archive root must contain only 'speak' (found: $ENTRIES)" >&2
    exit 1
fi
BINARY="$SCRATCH/extract/speak"
if [[ ! -x "$BINARY" ]]; then
    echo "error: speak is not executable" >&2
    exit 1
fi

ARCHS="$(lipo -archs "$BINARY")"
if [[ "$ARCHS" != "$ARCH" ]]; then
    echo "error: speak contains [$ARCHS] but must contain exactly [$ARCH]" >&2
    exit 1
fi
echo "==> architecture: $ARCHS"

EMBEDDED_VERSION="$(xcrun segedit "$BINARY" -extract __TEXT __speak_ver "$SCRATCH/version" \
    && tr -d '\0' < "$SCRATCH/version")"
if [[ "$EMBEDDED_VERSION" != "$VERSION" ]]; then
    echo "error: __TEXT,__speak_ver reads '$EMBEDDED_VERSION', expected '$VERSION'" >&2
    exit 1
fi
echo "==> linked version: $EMBEDDED_VERSION"

# SwiftPM ad-hoc signs every executable it links; only a Developer ID
# signature counts as signed here.
INFO="$(codesign -dv --verbose=4 "$BINARY" 2>&1 || true)"
if codesign --verify --strict --verbose=2 "$BINARY" 2>/dev/null && ! grep -q "^Signature=adhoc" <<< "$INFO"; then
    TEAM="$(sed -n 's/^TeamIdentifier=\(.*\)$/\1/p' <<< "$INFO" | head -n 1)"
    if [[ -z "$TEAM" || "$TEAM" == "not set" ]]; then
        echo "error: speak is signed without a team identifier" >&2
        exit 1
    fi
    echo "$INFO" | grep -q "runtime" || {
        echo "error: speak is signed without the hardened runtime" >&2
        exit 1
    }
    # Exactly the requirement SpeakCLIInstallerDependencies.verifyDeveloperIDSignature applies.
    codesign --verify --verbose=2 \
        -R="anchor apple generic and certificate leaf[subject.OU] = \"$TEAM\"" "$BINARY"
    echo "==> signature: Developer ID, team $TEAM, hardened runtime"
elif [[ "$REQUIRE_SIGNED" == true ]]; then
    echo "error: speak is not signed with a Developer ID identity" >&2
    exit 1
else
    echo "==> unsigned or ad-hoc signed (development archive)"
fi

if [[ "$REQUIRE_NOTARISED" == true ]]; then
    spctl --assess --type execute --verbose=2 "$BINARY"
    echo "==> Gatekeeper accepts speak"
fi

can_run=false
if [[ "$ARCH" == "$(uname -m)" ]]; then
    can_run=true
elif [[ "$ARCH" == "x86_64" ]] && arch -x86_64 /usr/bin/true 2>/dev/null; then
    can_run=true
fi
if [[ "$can_run" == true ]]; then
    REPORTED="$("$BINARY" --version)"
    if [[ "$REPORTED" != "speak $VERSION" ]]; then
        echo "error: 'speak --version' printed '$REPORTED', expected 'speak $VERSION'" >&2
        exit 1
    fi
    echo "==> $REPORTED"
else
    echo "==> $ARCH cannot run here; --version check skipped"
fi

echo "==> $(basename "$ARCHIVE") verified"
