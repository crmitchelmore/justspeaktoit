#!/usr/bin/env bash
# Runs SwiftFormat from the isolated tooling graph (Tooling/Package.swift), so
# the application/test graph never clones a formatter that no target links.
# Arguments are forwarded; it runs from the repository root so .swiftformat
# applies, e.g. `./scripts/swiftformat.sh .` or `./scripts/swiftformat.sh Sources/SpeakApp`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Each worktree would otherwise compile SwiftFormat from source (~90s of CPU) on its
# first autofix. The release binary is shared per user, keyed by the tooling pins,
# the toolchain and the architecture. JSTI_TOOLING_CACHE=off builds in place as before.
cache_root="${JSTI_TOOLING_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/jsti-tooling}"
if [ "$cache_root" != off ]; then
    key="$( { cat Tooling/Package.swift Tooling/Package.resolved; swift --version 2>&1; uname -m; } \
        | shasum -a 256 | cut -c1-16)"
    cached="$cache_root/swiftformat-$key/swiftformat"
    if [ ! -x "$cached" ]; then
        swift build --package-path Tooling -c release --product swiftformat >&2
        mkdir -p "$(dirname "$cached")"
        staged="$(mktemp "$cached.XXXXXX")"
        cp "$(swift build --package-path Tooling -c release --show-bin-path)/swiftformat" "$staged"
        chmod +x "$staged"
        mv -f "$staged" "$cached"  # atomic, so concurrent worktrees never run a partial copy
    fi
    exec "$cached" "$@"
fi

swift build --package-path Tooling -c release --product swiftformat >&2
exec "$(swift build --package-path Tooling -c release --show-bin-path)/swiftformat" "$@"
