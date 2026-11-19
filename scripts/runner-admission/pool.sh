#!/bin/bash
# Owner-run controls for the self-hosted pools (needs `gh` with repo admin rights).
#
#   scripts/runner-admission/pool.sh status               # runners, labels and routing variables
#   scripts/runner-admission/pool.sh main-off             # route main jobs back to hosted runners
#   scripts/runner-admission/pool.sh main-on              # resume routing main jobs to the pools
#   scripts/runner-admission/pool.sh add-reviewed-label <runner-name>
#   scripts/runner-admission/pool.sh use-default-mac-labels   # clear the JSTI_NATIVE_RUNNER_LABELS pin
#
# Self-hosted jobs never fall back to hosted runners: run main-off before taking a
# whole pool offline, or main jobs queue until a runner returns.
set -euo pipefail
repo="crmitchelmore/justspeaktoit"

case "${1:-status}" in
    status)
        gh api "repos/$repo/actions/runners" --jq \
            '.runners[] | "\(.name)\t\(.status)\t\(if .busy then "busy" else "idle" end)\t\([.labels[].name] | join(","))"' |
            column -t -s $'\t'
        echo
        for name in JSTI_SELF_HOSTED_MAIN JSTI_NATIVE_RUNNER_LABELS JSTI_LINUX_RUNNER_LABELS JSTI_NATIVE_APPROVED_SHA; do
            value="$(gh api "repos/$repo/actions/variables/$name" --jq .value 2>/dev/null)" || value="(unset)"
            printf '%-28s %s\n' "$name" "$value"
        done
        ;;
    main-off) gh variable set JSTI_SELF_HOSTED_MAIN --repo "$repo" --body off ;;
    main-on) gh variable delete JSTI_SELF_HOSTED_MAIN --repo "$repo" 2>/dev/null || true ;;
    use-default-mac-labels) gh variable delete JSTI_NATIVE_RUNNER_LABELS --repo "$repo" 2>/dev/null || true ;;
    add-reviewed-label)
        name="${2:?runner name}"
        case "$name" in *mac-mini-3*) echo "Refusing: mac-mini-3 is the owner's active Mac." >&2; exit 1 ;; esac
        id="$(gh api "repos/$repo/actions/runners" --jq ".runners[] | select(.name == \"$name\") | .id")"
        [ -n "$id" ] || { echo "No runner named $name" >&2; exit 1; }
        gh api -X POST "repos/$repo/actions/runners/$id/labels" -f 'labels[]=jsti-reviewed-local' --jq '[.labels[].name] | join(",")'
        ;;
    *) sed -n '2,12p' "$0"; exit 2 ;;
esac
