#!/usr/bin/env bash
# Called once per registry shape, always inside its own fresh dbus-run-session.
set -euo pipefail
binary="$1"
python="$2"
shape="$3"
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
backend=""
cleanup() {
    if [ -n "$backend" ]; then
        kill "$backend" 2>/dev/null || true
        wait "$backend" 2>/dev/null || true
    fi
    rm -f "$work/backend.log"
    rmdir "$work"
}
trap cleanup EXIT
export JSTI_ATSPI_SELECTION_FIXTURE=1
"$python" "$repo/scripts/linux-fake-atspi-selection.py" "$shape" >"$work/backend.log" 2>&1 &
backend=$!
for _ in $(seq 1 150); do
    grep -q "fake AT-SPI selection ready" "$work/backend.log" && break
    if ! kill -0 "$backend" 2>/dev/null; then cat "$work/backend.log" >&2; exit 1; fi
    sleep 0.02
done
if ! grep -q "fake AT-SPI selection ready" "$work/backend.log"; then
    cat "$work/backend.log" >&2
    echo "The isolated AT-SPI fixture did not become ready." >&2
    exit 1
fi
if ! JSTI_ATSPI_FIXTURE_PID="$backend" timeout 60 "$binary" --integration-test atspi-selection; then
    cat "$work/backend.log" >&2
    exit 1
fi
