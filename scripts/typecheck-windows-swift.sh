#!/usr/bin/env bash
# Compiles the Windows Swift targets (SpeakWindowsPlatform, SpeakDesktopHost,
# SpeakWindows and their tests) on a Linux or macOS host by replacing the
# native CWindowsSupport C++ adapter with its header plus an empty C file.
#
# This is a type check only: nothing links against Win32, so it cannot prove
# the Windows executable links or runs. It catches Swift-level breakage from
# shared-host refactors when no Windows machine is available. The Windows
# workflow remains the authority.
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
work="${SPEAK_WINDOWS_TYPECHECK_DIR:-${TMPDIR:-/tmp}/speak-windows-typecheck}"
mkdir -p "$work"
rm -rf "$work/Sources" "$work/Tests" "$work/Package.swift"
mkdir -p "$work/Sources/CWindowsSupport/include" "$work/Tests"

for source in "$repo"/Sources/*; do
    name="$(basename "$source")"
    case "$name" in
        CWindows*)
            # Native C/C++ adapters: keep only their public headers.
            mkdir -p "$work/Sources/$name/include"
            cp "$source/include/"*.h "$work/Sources/$name/include/"
            printf 'int jsti_typecheck_stub_%s(void) { return 0; }\n' "$name" > "$work/Sources/$name/stub.c"
            ;;
        *) ln -s "$source" "$work/Sources/$name" ;;
    esac
done
for tests in "$repo"/Tests/*; do
    ln -s "$tests" "$work/Tests/$(basename "$tests")"
done
cp "$repo/Package.swift" "$work/Package.swift"

cd "$work"
# Building individual targets compiles modules without linking, so the Win32
# import libraries named in the manifest are never needed.
export SPEAK_WINDOWS_TARGET=1
# SpeakWindowsPlatformTests is left out: it uses Windows-only automation
# client code (`#if os(Windows)`) and does not depend on the shared host.
for target in SpeakWindowsPlatform SpeakDesktopHost SpeakWindows SpeakDesktopHostTests; do
    if grep -q "name: \"$target\"" Package.swift; then
        echo "== type-checking $target"
        swift build --target "$target" "$@"
    fi
done
