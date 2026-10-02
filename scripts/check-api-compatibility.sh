#!/usr/bin/env bash
# Public-API compatibility gate (issue #680).
#
# Diagnoses breaking changes to the exported SwiftPM library products against
# a baseline treeish (in CI: the PR's base branch). An undeclared change that
# removes or incompatibly alters a public symbol fails here.
#
# Intentional update workflow: a PR whose title carries the conventional
# breaking marker (`type!:` / `type(scope)!:`) declares an intentional API
# break, so the gate reports the diff but does not fail. PR review carries the
# migration note. Main follows the commissioned Alpha process; Stable version
# selection and publication remain explicit owner decisions, not an automatic
# major release caused by this marker.

set -uo pipefail

BASELINE="${1:?usage: check-api-compatibility.sh <baseline-treeish>}"
PR_TITLE="${PR_TITLE:-}"

PRODUCTS=(SpeakCore SpeakSync SpeakiOSLib SpeakHotKeys SpeakAutomationKit)

# A newly introduced product has no baseline API. Once it exists on the base
# branch it must stay covered, even if the current branch removes it. Evaluate
# the baseline manifest itself: a text match could find a comment or target
# name that is not an exported product. dump-package does not resolve or build
# dependencies, and the disposable directory isolates manifest evaluation.
if ! baseline_manifest_dir=$(mktemp -d "${TMPDIR:-/tmp}/speak-api-baseline.XXXXXX"); then
    echo "==> Unable to prepare baseline manifest evaluation" >&2
    exit 1
fi
trap 'rm -rf -- "$baseline_manifest_dir"' EXIT
if ! git show "${BASELINE}:Package.swift" > "$baseline_manifest_dir/Package.swift"; then
    echo "==> Unable to read baseline Package.swift" >&2
    exit 1
fi
if ! swift package --package-path "$baseline_manifest_dir" dump-package > "$baseline_manifest_dir/package.json"; then
    echo "==> Unable to evaluate baseline package products" >&2
    exit 1
fi
if ! baseline_has_watch=$(python3 - "$baseline_manifest_dir/package.json" <<'PY'
import json
import sys

def unique_fields(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON field: {key}")
        result[key] = value
    return result

def reject_constant(value):
    raise ValueError(f"invalid JSON constant: {value}")

try:
    with open(sys.argv[1], encoding="utf-8") as stream:
        manifest = json.load(stream, object_pairs_hook=unique_fields, parse_constant=reject_constant)
    if not isinstance(manifest, dict) or not isinstance(manifest.get("products"), list):
        raise ValueError("expected a products array")
    names = []
    for product in manifest["products"]:
        if not isinstance(product, dict) or not isinstance(product.get("name"), str) or not product["name"]:
            raise ValueError("expected a nonempty product name")
        names.append(product["name"])
    if len(names) != len(set(names)):
        raise ValueError("duplicate product names")
except (OSError, UnicodeError, ValueError) as error:
    sys.exit(f"Invalid baseline package products: {error}")
print("yes" if "SpeakWatchCore" in names else "no")
PY
); then
    echo "==> Unable to establish baseline API coverage" >&2
    exit 1
fi
if [[ "$baseline_has_watch" == "yes" ]]; then
    PRODUCTS+=(SpeakWatchCore)
elif [[ "$baseline_has_watch" == "no" ]]; then
    echo "==> Baseline has no SpeakWatchCore product; skipping its initial API comparison"
else
    echo "==> Invalid baseline product decision" >&2
    exit 1
fi

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

# Reviewed additive changes are listed in the allowlist and do not fail the
# gate. The tool's own --breakage-allowlist-path does not match SwiftPM's
# rendered findings, so the filtering is done here against the same text the
# report prints. See the allowlist file for what may be listed.
ALLOWLIST="$(dirname "$0")/api-breakage-allowlist.txt"
findings=$(grep -o 'API breakage: .*' <<< "$output" | sort -u)
allowed=""
if [[ -f "$ALLOWLIST" ]]; then
    allowed=$(grep -v '^[[:space:]]*#' "$ALLOWLIST" | grep -v '^[[:space:]]*$')
fi

remaining=$findings
if [[ -n "$allowed" ]]; then
    remaining=$(grep -vxF -f <(printf '%s\n' "$allowed") <<< "$findings" || true)
    ignored=$(grep -xF -f <(printf '%s\n' "$allowed") <<< "$findings" || true)
    if [[ -n "$ignored" ]]; then
        echo "==> Ignoring reviewed additive changes from ${ALLOWLIST}:"
        sed 's/^/    /' <<< "$ignored"
    fi
fi

if [[ -z "${remaining//[[:space:]]/}" ]]; then
    echo "==> No unreviewed public API breakage against ${BASELINE}"
    exit 0
fi

echo "==> Unreviewed breaking changes:" >&2
sed 's/^/    /' <<< "$remaining" >&2

breaking_title_pattern='^[a-z]+(\([^)]+\))?!:'
if [[ "$PR_TITLE" =~ $breaking_title_pattern ]]; then
    echo "==> Breaking API change declared by the PR title's '!' marker;"
    echo "    allowing the declared migration. Ensure the PR body"
    echo "    documents the migration path."
    exit 0
fi

cat >&2 << 'MSG'
==> Breaking public API change without a declared migration.
    Either restore compatibility (a deprecated shim forwarding to the new
    API), or declare the break by adding the conventional-commit '!' marker
    to the PR title (e.g. `refactor!: ...`) with a migration note in the PR
    body. See issue #680.
MSG
exit 1
