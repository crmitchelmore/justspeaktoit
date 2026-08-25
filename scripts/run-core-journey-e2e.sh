#!/usr/bin/env bash
set -euo pipefail

# Fast, hermetic regression gate for the external contracts that make up the
# macOS dictation journey. Keep this list intentionally small: detailed edge
# cases remain in their owning suites, while this gate proves every user-visible
# boundary on every relevant PR.
readonly budget_seconds="${CORE_JOURNEY_BUDGET_SECONDS:-480}"
readonly artifacts_dir="${CORE_JOURNEY_ARTIFACTS_DIR:-.artifacts/core-journey-e2e}"
readonly filter='GestureDetectorTests|LiveTextInserterStreamingTests|PostProcessingManagerTests|OpenAITranscriptionProviderErrorTests|MissingLiveAPIKeyAlertTests|TextOutputTests|StreamingClientContractTests|AutomationIntentSupportTests'

mkdir -p "$artifacts_dir"
started_at="$(date +%s)"

python3 - "$budget_seconds" "$artifacts_dir/test.log" "$filter" <<'PY'
import subprocess
import sys

budget = int(sys.argv[1])
log_path = sys.argv[2]
test_filter = sys.argv[3]
command = ["swift", "test", "--filter", test_filter]

with open(log_path, "w", encoding="utf-8") as log:
    log.write("command: " + " ".join(command) + "\n")
    log.flush()
    try:
        result = subprocess.run(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=budget,
            check=False,
        )
    except subprocess.TimeoutExpired as error:
        output = error.stdout or ""
        if isinstance(output, bytes):
            output = output.decode("utf-8", errors="replace")
        log.write(output)
        print(output, end="")
        print(f"Core journey gate exceeded its {budget}s test budget.", file=sys.stderr)
        raise SystemExit(124)

    log.write(result.stdout)
    print(result.stdout, end="")
    raise SystemExit(result.returncode)
PY

elapsed="$(( $(date +%s) - started_at ))"
printf 'core_journey_elapsed_seconds=%s\n' "$elapsed" | tee "$artifacts_dir/timing.txt"
if (( elapsed > budget_seconds )); then
  echo "Core journey gate took ${elapsed}s; budget is ${budget_seconds}s." >&2
  exit 124
fi

