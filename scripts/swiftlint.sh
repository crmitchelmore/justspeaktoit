#!/usr/bin/env bash
# Runs SwiftLint from the isolated tooling graph (Tooling/Package.swift).
#
# Lint tooling deliberately does not share the application/test dependency
# graph: swift-snapshot-testing constrains swift-syntax in a way that silently
# downgraded SwiftLint when both lived in one graph (issue #677). Resolving
# Tooling/ separately keeps the linter at the version pinned in
# Tooling/Package.resolved regardless of app/test dependency changes.
#
# All arguments are forwarded to the swiftlint binary, and swiftlint runs from
# the repository root so relative paths in .swiftlint.yml and the path-keyed
# .swiftlint-baseline.json keep working.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Resolve the tooling graph; this also downloads the SwiftLint binary
# artifact bundle into Tooling/.build/artifacts.
swift package --package-path Tooling resolve

case "$(uname -s)" in
    Darwin) platform_dir="macos" ;;
    Linux) platform_dir="linux/$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')" ;;
    *) echo "swiftlint.sh: unsupported platform $(uname -s)" >&2; exit 1 ;;
esac

swiftlint_bin="$(find Tooling/.build/artifacts -type f -perm -u+x \
    -path "*/SwiftLintBinary.artifactbundle/$platform_dir/*" -name swiftlint | head -n 1)"

if [ -z "$swiftlint_bin" ]; then
    echo "swiftlint.sh: SwiftLint binary not found under Tooling/.build/artifacts" >&2
    exit 1
fi

exec "$swiftlint_bin" "$@"
