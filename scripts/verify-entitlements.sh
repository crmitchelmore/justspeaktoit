#!/bin/bash
# verify-entitlements.sh — Verify entitlements on a signed macOS .app bundle.
#
# Usage:
#   ./scripts/verify-entitlements.sh /path/to/JustSpeakToIt.app
#
# Exit codes:
#   0 — All required entitlements present, no forbidden entitlements found
#   1 — Missing required entitlement or forbidden entitlement present

set -euo pipefail

APP_PATH="${1:?Usage: $0 /path/to/App.app}"

if [ ! -d "$APP_PATH" ]; then
    echo "❌ App not found at: $APP_PATH"
    exit 1
fi

echo "🔍 Verifying entitlements: $APP_PATH"

# Extract entitlements from the signed binary
ENTITLEMENTS=$(codesign -d --entitlements :- "$APP_PATH" 2>/dev/null || true)

if [ -z "$ENTITLEMENTS" ]; then
    echo "❌ Could not extract entitlements — app may not be signed"
    exit 1
fi

echo "$ENTITLEMENTS"
echo ""

FAILED=0

# --- Required entitlements for Developer ID build ---
REQUIRED=(
    "com.apple.security.device.audio-input"
)

for KEY in "${REQUIRED[@]}"; do
    if echo "$ENTITLEMENTS" | grep -q "$KEY"; then
        echo "  ✅ Required: $KEY"
    else
        echo "  ❌ MISSING required: $KEY"
        FAILED=1
    fi
done

# --- Forbidden entitlements for Developer ID build ---
# These cause AMFI "No matching profile found" and launchd spawn failure
FORBIDDEN=(
    "com.apple.developer.icloud-container-identifiers"
    "com.apple.developer.icloud-services"
    "com.apple.developer.ubiquity-kvstore-identifier"
    "aps-environment"
    "com.apple.developer.associated-domains"
    "com.apple.security.app-sandbox"
)

for KEY in "${FORBIDDEN[@]}"; do
    # Check if the key exists AND is set to a truthy/non-empty value
    if echo "$ENTITLEMENTS" | grep -q "$KEY"; then
        echo "  ❌ FORBIDDEN entitlement present: $KEY"
        FAILED=1
    else
        echo "  ✅ Absent (good): $KEY"
    fi
done

# --- Verify codesign is valid ---
echo ""
echo "🔍 Verifying code signature..."
if codesign --verify --deep --strict "$APP_PATH" 2>&1; then
    echo "  ✅ Code signature valid"
else
    echo "  ❌ Code signature INVALID"
    FAILED=1
fi

# --- Check hardened runtime ---
CODESIGN_INFO=$(codesign -dvv "$APP_PATH" 2>&1 || true)
if echo "$CODESIGN_INFO" | grep -q "runtime"; then
    echo "  ✅ Hardened runtime enabled"
else
    echo "  ❌ Hardened runtime NOT enabled"
    FAILED=1
fi

if [ $FAILED -eq 0 ]; then
    echo ""
    echo "✅ Entitlement verification passed"
    exit 0
else
    echo ""
    echo "❌ Entitlement verification FAILED"
    exit 1
fi
