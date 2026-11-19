#!/bin/bash
# Owner-run: install the reviewed admission hook into a self-hosted runner.
#
#   scripts/runner-admission/install.sh <runner-directory> <mac|linux> [--dry-run]
#
# Examples (run ON the machine, from a main checkout):
#   bravo-mini:     scripts/runner-admission/install.sh ~/actions-runner-justspeaktoit mac
#   macbook-intel:  scripts/runner-admission/install.sh ~/actions-runner-justspeaktoit mac
#   omarchy:        scripts/runner-admission/install.sh ~/actions-runner-justspeaktoit linux
#
# Never install it on mac-mini-3 (the owner's active Mac): it must not carry
# jsti-reviewed-local, so routing never selects it.
#
# It copies job-started.sh to <runner>/admission/, writes the per-role allowed-jobs
# list, keeps any existing approved-shas, points ACTIONS_RUNNER_HOOK_JOB_STARTED at
# the hook in <runner>/.env (backing up .env first) and makes the policy files
# read-only. Restart the runner service afterwards (./svc.sh stop && ./svc.sh start).
set -euo pipefail

usage() { echo "usage: $0 <runner-directory> <mac|linux> [--dry-run]" >&2; exit 2; }
[ $# -ge 2 ] || usage
runner="$(cd "$1" && pwd)"
role="$2"
dry_run="${3:-}"
source_dir="$(cd "$(dirname "$0")" && pwd)"

[ -f "$runner/.runner" ] || { echo "$runner is not a configured runner directory (.runner missing)" >&2; exit 1; }
if grep -q 'mac-mini-3' "$runner/.runner"; then
    echo "Refusing: mac-mini-3 is the owner's active Mac and stays out of the reviewed pool." >&2
    exit 1
fi

case "$role" in
    mac) jobs="$source_dir/allowed-jobs-mac" ;;
    linux) jobs="$source_dir/allowed-jobs-linux" ;;
    *) usage ;;
esac

admission="$runner/admission"
hook="$admission/job-started.sh"
if [ "$dry_run" = "--dry-run" ]; then
    echo "Would install $source_dir/job-started.sh -> $hook"
    echo "Would install $jobs -> $admission/allowed-jobs:"
    sed 's/^/    /' "$jobs"
    echo "Would set ACTIONS_RUNNER_HOOK_JOB_STARTED=$hook in $runner/.env"
    exit 0
fi

mkdir -p "$admission"
[ -f "$hook" ] && cp -p "$hook" "$hook.bak.$(date +%s)"
chmod u+w "$hook" "$admission/allowed-jobs" 2>/dev/null || true
install -m 0555 "$source_dir/job-started.sh" "$hook"
install -m 0444 "$jobs" "$admission/allowed-jobs"
touch "$admission/approved-shas"

env_file="$runner/.env"
touch "$env_file"
cp -p "$env_file" "$env_file.bak.$(date +%s)"
grep -v '^ACTIONS_RUNNER_HOOK_JOB_STARTED=' "$env_file" > "$env_file.tmp" || true
echo "ACTIONS_RUNNER_HOOK_JOB_STARTED=$hook" >> "$env_file.tmp"
mv "$env_file.tmp" "$env_file"

echo "Installed admission hook for role '$role' in $admission."
echo "Next: restart the runner service (cd '$runner' && ./svc.sh stop && ./svc.sh start),"
echo "then confirm labels with: scripts/runner-admission/pool.sh status"
