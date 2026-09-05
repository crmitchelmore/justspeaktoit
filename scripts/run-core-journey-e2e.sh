#!/usr/bin/env bash
set -euo pipefail

# Contract regression gate; launched-app/hardware coverage is tracked separately.
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$script_dir/run-core-journey-e2e.py"
