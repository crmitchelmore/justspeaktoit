#!/bin/bash
# Fail-closed admission policy for a reviewed self-hosted runner (Docs/native-runner-pool.md).
#
# Install as the runner's ACTIONS_RUNNER_HOOK_JOB_STARTED (see
# scripts/runner-admission/install.sh). It admits only crmitchelmore/justspeaktoit jobs that are:
#   - push or schedule on refs/heads/main, defined by a main workflow, whose commit is
#     on main as fetched from GitHub by this hook (no manual approval), or
#   - a same-repository pull_request whose head SHA is listed in approved-shas.
# If allowed-jobs exists, GITHUB_JOB must also be listed there.
#
# Workflow-controlled environment cannot redirect these checks: tools, the remote
# and the policy files are fixed paths, not environment variables.
set -u
REPO="crmitchelmore/justspeaktoit"
REMOTE="https://github.com/crmitchelmore/justspeaktoit.git"
GIT="/usr/bin/git"
DIR="$(cd "$(dirname "$0")" && pwd)"
ALLOW="$DIR/approved-shas"
JOBS="$DIR/allowed-jobs"
MIRROR="$DIR/main.git"
HOST="$(hostname -s 2>/dev/null || hostname)"

deny() { echo "::error::Admission denied on $HOST: $*"; exit 1; }

event_field() {
    if [ -x /usr/bin/plutil ]; then
        /usr/bin/plutil -extract "$1" raw -o - "$GITHUB_EVENT_PATH" 2>/dev/null
    else
        /usr/bin/python3 - "$1" "$GITHUB_EVENT_PATH" <<'PY' 2>/dev/null
import json, sys
value = json.load(open(sys.argv[2], encoding='utf-8'))
for key in sys.argv[1].split('.'):
    value = value[key]
print(value)
PY
    fi
}

# Fetch main's history (commits only) into a private mirror, then require the job's
# commit to be main's tip or one of its ancestors (a run queued behind newer merges).
on_main() {
    if [ ! -d "$MIRROR" ]; then
        "$GIT" init --bare --quiet "$MIRROR" || return 1
    fi
    "$GIT" --git-dir="$MIRROR" fetch --quiet --no-tags --filter=tree:0 "$REMOTE" \
        "+refs/heads/main:refs/heads/main" || return 1
    "$GIT" --git-dir="$MIRROR" merge-base --is-ancestor "$1" refs/heads/main 2>/dev/null
}

[ "${GITHUB_REPOSITORY:-}" = "$REPO" ] || deny "repository ${GITHUB_REPOSITORY:-unset}"
JOB="${GITHUB_JOB:-}"
if [ -f "$JOBS" ]; then
    grep -qxF "$JOB" "$JOBS" || deny "job ${JOB:-unset} is not in $JOBS"
fi

case "${GITHUB_EVENT_NAME:-}" in
    push | schedule)
        [ "${GITHUB_REF:-}" = "refs/heads/main" ] || deny "$GITHUB_EVENT_NAME ref ${GITHUB_REF:-unset}"
        case "${GITHUB_WORKFLOW_REF:-}" in
            "$REPO/.github/workflows/"*"@refs/heads/main") ;;
            *) deny "workflow ${GITHUB_WORKFLOW_REF:-unset} is not defined on main" ;;
        esac
        SHA="${GITHUB_SHA:-}"
        [[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || deny "missing source SHA"
        on_main "$SHA" || deny "commit $SHA is not on $REPO main (or GitHub was unreachable)"
        echo "Admission accepted: main $GITHUB_EVENT_NAME $SHA job ${JOB:-?}"
        ;;
    pull_request)
        HEAD_REPO="$(event_field pull_request.head.repo.full_name)"
        [ "$HEAD_REPO" = "$REPO" ] || deny "fork pull request ($HEAD_REPO)"
        SHA="$(event_field pull_request.head.sha)"
        [[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || deny "missing source SHA"
        grep -qxF "$SHA" "$ALLOW" 2>/dev/null || deny "SHA $SHA not in $ALLOW"
        echo "Admission accepted: approved pull_request $SHA job ${JOB:-?}"
        ;;
    *) deny "event ${GITHUB_EVENT_NAME:-unset}" ;;
esac
