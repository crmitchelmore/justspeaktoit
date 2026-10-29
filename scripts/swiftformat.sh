#!/usr/bin/env bash
# Runs SwiftFormat from the isolated tooling graph (Tooling/Package.swift), so
# the application/test graph never clones a formatter that no target links.
# Arguments are forwarded; it runs from the repository root so .swiftformat
# applies, e.g. `./scripts/swiftformat.sh .` or `./scripts/swiftformat.sh Sources/SpeakApp`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

swift build --package-path Tooling -c release --product swiftformat >&2
exec "$(swift build --package-path Tooling -c release --show-bin-path)/swiftformat" "$@"
