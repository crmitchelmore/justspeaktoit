#!/usr/bin/env bash
set -euo pipefail
umask 077
export PYTHONDONTWRITEBYTECODE=1 GIT_OPTIONAL_LOCKS=0
recipe="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
exec timeout --kill-after=120s 2400s python3 "$recipe/registry-linux-supported-fs-gate.py" host
