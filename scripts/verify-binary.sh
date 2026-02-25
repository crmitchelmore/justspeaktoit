#!/bin/bash
# verify-binary.sh — Verify all dynamic library dependencies in a macOS binary resolve.
#
# Usage:
#   ./scripts/verify-binary.sh /path/to/JustSpeakToIt.app
#   ./scripts/verify-binary.sh /path/to/executable
#
# Exit codes:
#   0 — All dylib dependencies resolve
#   1 — Missing or unresolvable dependencies found

set -euo pipefail

APP_PATH="${1:?Usage: $0 /path/to/App.app or /path/to/executable}"

if [ ! -e "$APP_PATH" ]; then echo "❌ Not found: $APP_PATH"; exit 1; fi

echo "🔍 Verifying binary dependencies: $APP_PATH"

# --- Resolve main executable and bundle root ---
BUNDLE_DIR=""
if [ -d "$APP_PATH" ] && [[ "$APP_PATH" == *.app ]]; then
    BUNDLE_DIR="$APP_PATH"
    EXEC_NAME=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" \
        "$BUNDLE_DIR/Contents/Info.plist" 2>/dev/null || basename "$APP_PATH" .app)
    MAIN_EXEC="$BUNDLE_DIR/Contents/MacOS/$EXEC_NAME"
else
    MAIN_EXEC="$APP_PATH"
fi

if [ ! -f "$MAIN_EXEC" ]; then echo "❌ Executable not found: $MAIN_EXEC"; exit 1; fi

FAILED=0

check_binary() {
    local binary="$1" label="${2:-$1}"
    local deps; deps=$(otool -L "$binary" 2>/dev/null | tail -n +2 | awk '{print $1}') || return
    for dep in $deps; do
        # System libraries — assumed present
        [[ "$dep" == /System/* || "$dep" == /usr/lib/* ]] && continue
        # @rpath — resolve into Frameworks/
        if [[ "$dep" == @rpath/* ]]; then
            if [ -n "$BUNDLE_DIR" ]; then
                local resolved="$BUNDLE_DIR/Contents/Frameworks/${dep#@rpath/}"
                if [ ! -e "$resolved" ]; then
                    echo "  ❌ Unresolved @rpath: $dep (in $label)"; FAILED=1
                fi
            else
                echo "  ⚠️  @rpath outside bundle: $dep (in $label)"
            fi; continue
        fi
        # @executable_path
        if [[ "$dep" == @executable_path/* ]]; then
            local resolved="$(dirname "$MAIN_EXEC")/${dep#@executable_path/}"
            [ ! -e "$resolved" ] && echo "  ❌ Unresolved: $dep (in $label)" && FAILED=1
            continue
        fi
        # @loader_path — context-dependent, skip
        [[ "$dep" == @loader_path/* ]] && continue
        # Absolute path
        [ ! -e "$dep" ] && echo "  ❌ Missing dylib: $dep (in $label)" && FAILED=1
    done
}

# --- Check main executable ---
echo "  Checking main executable: $MAIN_EXEC"
check_binary "$MAIN_EXEC" "main executable"

# --- Check embedded dylibs/frameworks in bundle ---
if [ -n "$BUNDLE_DIR" ]; then
    while IFS= read -r -d '' lib; do
        check_binary "$lib" "${lib#"$BUNDLE_DIR"/}"
    done < <(find "$BUNDLE_DIR/Contents" \( -name "*.dylib" -o -name "*.framework" \) \
        -type f -print0 2>/dev/null)
fi

echo ""
if [ $FAILED -eq 0 ]; then echo "✅ All binary dependencies resolved"; exit 0
else echo "❌ Binary dependency verification FAILED"; exit 1; fi
