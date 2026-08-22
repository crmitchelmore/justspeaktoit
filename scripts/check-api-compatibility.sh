#!/usr/bin/env bash
# Public-API compatibility gate (issue #680).
#
# Diagnoses breaking changes to the exported SwiftPM library products against
# a baseline treeish (in CI: the PR's base branch). A non-major change that
# removes or incompatibly alters a public symbol fails here.
#
# Intentional update workflow: a PR whose title carries the conventional
# breaking marker (`type!:` / `type(scope)!:`) declares a major release, so
# the gate reports the diff but does not fail — auto-release will publish it
# as a major version and the PR review carries the migration note.

set -uo pipefail

BASELINE="${1:?usage: check-api-compatibility.sh <baseline-treeish>}"
PR_TITLE="${PR_TITLE:-}"

PRODUCTS=(SpeakCore SpeakSync SpeakiOSLib SpeakHotKeys SpeakAutomationKit)

product_args=()
for product in "${PRODUCTS[@]}"; do
    product_args+=(--products "$product")
done

echo "==> Diagnosing public API against ${BASELINE} for: ${PRODUCTS[*]}"
output=$(swift package diagnose-api-breaking-changes "$BASELINE" "${product_args[@]}" 2>&1)
status=$?
echo "$output"

if [[ $status -eq 0 ]]; then
    echo "==> Public API is compatible with ${BASELINE}"
    exit 0
fi

# The command exits non-zero both for detected breakage and for tooling
# failures; only treat runs that actually printed findings as breakage.
if ! grep -q "API breakage" <<< "$output"; then
    echo "==> swift package diagnose-api-breaking-changes failed to run" >&2
    exit "$status"
fi

breaking_title_pattern='^[a-z]+(\([^)]+\))?!:'
if [[ "$PR_TITLE" =~ $breaking_title_pattern ]]; then
    echo "==> Breaking API change declared by the PR title's '!' marker;"
    echo "    allowing under the major-release workflow. Ensure the PR body"
    echo "    documents the migration path."
    exit 0
fi

cat >&2 << 'MSG'
==> Breaking public API change without a declared major release.
    Either restore compatibility (a deprecated shim forwarding to the new
    API), or declare the break by adding the conventional-commit '!' marker
    to the PR title (e.g. `refactor!: ...`) with a migration note in the PR
    body. See issue #680.
MSG
exit 1
