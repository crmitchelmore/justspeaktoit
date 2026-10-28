#!/usr/bin/env bash
# Retain complete, matching debug information before stripping a staged CLI.
# Usage: prepare-mac-cli-symbols.sh <staged-binary> <destination.dSYM>
# Retained bundles are UUID-keyed siblings of the requested naming prefix.
set -euo pipefail

BINARY="${1:-}"
DESTINATION="${2:-}"
fail() { echo "error: CLI debug symbol preparation failed: $1" >&2; exit 1; }
[[ -f "$BINARY" && ! -L "$BINARY" ]] || fail "missing staged executable"
[[ "$DESTINATION" == *.dSYM && ! -L "$DESTINATION" ]] \
    || fail "symbol destination must be a nonsymlink dSYM naming prefix"
mkdir -p "$(dirname "$DESTINATION")"
SYMBOLS_PARENT="$(cd "$(dirname "$DESTINATION")" && pwd -P)"
DESTINATION="$SYMBOLS_PARENT/$(basename "$DESTINATION")"
WORK="$(mktemp -d "$SYMBOLS_PARENT/.cli-symbols.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
DSYM="$WORK/speak.dSYM"

# Warnings about missing object files can accompany a successful dsymutil exit.
# Do not replace complete debug maps with a partial dSYM and then strip them.
if ! xcrun dsymutil --verify "$BINARY" -o "$DSYM" > "$WORK/generate.log" 2>&1; then
    fail "dSYM generation or DWARF verification failed"
fi
if grep -Eiq '(warning|error):' "$WORK/generate.log"; then
    fail "dSYM generation reported incomplete or invalid debug information"
fi
DWARF="$DSYM/Contents/Resources/DWARF/speak"
[[ -f "$DWARF" && ! -L "$DWARF" && -s "$DWARF" ]] || fail "missing DWARF data"

# Compare UUID and architecture pairs, ignoring only dwarfdump's printed path.
uuids() {
    xcrun dwarfdump --uuid "$1" | awk '
        $1 != "UUID:" || length($2) != 36 || $2 !~ /^[0-9A-Fa-f-]+$/ { exit 1 }
        $3 != "(arm64)" && $3 != "(x86_64)" { exit 1 }
        { arch = substr($3, 2, length($3) - 2)
          if (seen[arch]++) exit 1
          print arch, toupper($2); count++ }
        END { if (!count) exit 1 }
    ' | LC_ALL=C sort
}
uuids "$BINARY" > "$WORK/before" || fail "invalid executable UUIDs"
uuids "$DWARF" > "$WORK/symbols" || fail "invalid dSYM UUIDs"
cmp -s "$WORK/before" "$WORK/symbols" || fail "dSYM UUID or architecture mismatch"
xcrun lipo -archs "$BINARY" | tr ' ' '\n' | sed '/^$/d' | LC_ALL=C sort > "$WORK/archs"
cut -d ' ' -f1 "$WORK/before" > "$WORK/uuid-archs"
cmp -s "$WORK/archs" "$WORK/uuid-archs" || fail "incomplete executable UUID coverage"
while read -r ARCH; do
    if ! xcrun dwarfdump --verify --arch="$ARCH" "$DSYM" > "$WORK/verify.log" 2>&1; then
        fail "invalid per-architecture DWARF data"
    fi
    if grep -Eiq '(warning|error):' "$WORK/verify.log"; then
        fail "DWARF verification reported a warning or error"
    fi
    if ! xcrun dwarfdump --debug-info --arch="$ARCH" "$DSYM" 2> "$WORK/info.log" \
        | awk '/DW_TAG_compile_unit/ { found = 1 } END { exit !found }'; then
        fail "missing per-architecture compilation units"
    fi
    if grep -Eiq '(warning|error):' "$WORK/info.log"; then
        fail "incomplete per-architecture compilation units"
    fi
done < "$WORK/archs"

# UUID-keyed siblings preserve previous builds. Reuse only a byte-identical
# bundle after fresh generation and verification, including changed debug data
# for the same UUID. Never traverse symlinks or special files in old bundles.
KEY="$(cut -d ' ' -f2 "$WORK/before" | paste -sd- -)"
STEM="${DESTINATION%.dSYM}-$KEY"
RETAINED=""
for CANDIDATE in "$STEM.dSYM" "$STEM-"*.dSYM; do
    SUFFIX="${CANDIDATE#"$STEM"}"
    if [[ "$SUFFIX" != .dSYM && ! "$SUFFIX" =~ ^-[A-Za-z0-9]{6}[.]dSYM$ ]]; then
        continue
    fi
    [[ -d "$CANDIDATE" && ! -L "$CANDIDATE" ]] || continue
    if ! find "$CANDIDATE" ! -type d ! -type f -print -quit > "$WORK/special" 2>/dev/null; then
        continue
    fi
    [[ ! -s "$WORK/special" ]] || continue
    if diff -qr "$DSYM" "$CANDIDATE" >/dev/null 2>&1; then
        RETAINED="$CANDIDATE"
        break
    fi
done
if [[ -z "$RETAINED" ]]; then
    RETAINED="$STEM.dSYM"
    if [[ -e "$RETAINED" || -L "$RETAINED" ]]; then
        RETAINED="$STEM-${WORK##*.cli-symbols.}.dSYM"
    fi
    # Reserve an owned directory without replacing any existing sibling.
    mkdir "$RETAINED" || fail "cannot reserve retained symbol bundle"
    cp -R "$DSYM/." "$RETAINED" || fail "cannot retain verified symbols"
    diff -qr "$DSYM" "$RETAINED" >/dev/null 2>&1 || fail "retained symbol copy differs"
fi

# Debug entries only: retain local/global symbols and all runtime metadata.
# Callers sign the staged executable only after this operation succeeds.
/usr/bin/strip -S "$BINARY"
uuids "$BINARY" > "$WORK/after" || fail "invalid stripped executable UUIDs"
cmp -s "$WORK/before" "$WORK/after" || fail "stripping changed executable identity"
echo "Verified and retained CLI dSYM; removed debug symbol entries."
