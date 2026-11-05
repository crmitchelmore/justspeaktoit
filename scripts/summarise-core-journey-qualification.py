#!/usr/bin/env python3
"""Decide the #802 flake gate from per-iteration launched-app receipts.

Every shard must have exactly RUNS_PER_SHARD executions with no failure, skip,
missing iteration or retry, and at least COLD_RUNS of them must be the first
execution on a fresh hosted runner. Any failure fails qualification: there is no
retry or best-of selection.

Receipts from every attempt of the same run are considered. A job (shard and
runner) may be supplied by a later attempt only when no earlier attempt of it
produced any iteration receipt, i.e. it failed before testing (for example a
setup download error). A job whose iterations ran in more than one attempt is a
retry and disqualifies; an incomplete job leaves its shard short of the total.
"""

import json
from pathlib import Path
import sys

RUNS_PER_SHARD = 20
COLD_RUNS = 5


def load_receipts(root):
    return [json.loads(path.read_text(encoding="utf-8")) for path in sorted(Path(root).rglob("iteration.json"))]


def assess(receipts, shards):
    errors = []
    shas = {r.get("sha") for r in receipts}
    if len(shas) > 1:
        errors.append(f"receipts span more than one source revision: {sorted(map(str, shas))}")
    summary = {}
    for shard in shards:
        rows = sorted((r for r in receipts if r.get("shard") == shard),
                      key=lambda r: (int(r["runner"]), int(r["iteration"])))
        keys = [(int(r["runner"]), int(r["iteration"])) for r in rows]
        if len(keys) != len(set(keys)):
            errors.append(f"{shard}: duplicate iteration receipts (a retry is not admissible)")
        attempts = {}
        for r in rows:
            attempts.setdefault(int(r["runner"]), set()).add(int(r.get("run_attempt", 1)))
        for runner, seen in sorted(attempts.items()):
            if len(seen) > 1:
                errors.append(f"{shard}: runner {runner} ran iterations in attempts {sorted(seen)} "
                              "(a retry after testing is not admissible)")
        passed = [r for r in rows if r.get("exit_code") == 0 and not r.get("coverage_errors")]
        cold = [r for r in rows if r.get("cold")]
        durations = sorted(float(r.get("seconds", 0)) for r in rows)
        p95 = durations[max(0, -(-len(durations) * 95 // 100) - 1)] if durations else None
        summary[shard] = {
            "runs": len(rows), "passed": len(passed), "cold": len(cold),
            "cold_passed": sum(1 for r in cold if r in passed),
            "max_seconds": durations[-1] if durations else None, "p95_seconds": p95,
        }
        if len(rows) != RUNS_PER_SHARD:
            errors.append(f"{shard}: expected {RUNS_PER_SHARD} executions, found {len(rows)}")
        for row in rows:
            if row not in passed:
                errors.append(f"{shard}: runner {row['runner']} iteration {row['iteration']} failed "
                              f"(exit {row.get('exit_code')}, {row.get('coverage_errors') or 'see artifacts'})")
        if summary[shard]["cold_passed"] < COLD_RUNS:
            errors.append(f"{shard}: expected at least {COLD_RUNS} passing cold-runner executions, "
                          f"found {summary[shard]['cold_passed']}")
    return errors, summary


def markdown(receipts, summary, errors):
    lines = ["## Core journey flake qualification (#802)", "",
             "| Shard | Runs | Passed | Cold passed | p95 test s | Max test s |", "| --- | --- | --- | --- | --- | --- |"]
    for shard, row in summary.items():
        lines.append(f"| {shard} | {row['runs']} | {row['passed']} | {row['cold_passed']}/{row['cold']} "
                     f"| {row['p95_seconds']} | {row['max_seconds']} |")
    lines += ["", "| Shard | Runner | Attempt | Iteration | Cold | Exit | Test s |", "| --- | --- | --- | --- | --- | --- | --- |"]
    for r in sorted(receipts, key=lambda r: (r["shard"], int(r["runner"]), int(r["iteration"]))):
        lines.append(f"| {r['shard']} | {r['runner']} | {r.get('run_attempt', 1)} | {r['iteration']} "
                     f"| {'yes' if r.get('cold') else 'no'} "
                     f"| {r.get('exit_code')} | {r.get('seconds')} |")
    lines += ["", "**Result:** " + ("qualified" if not errors else "NOT qualified")]
    lines += [f"- {error}" for error in errors]
    return "\n".join(lines) + "\n"


def main(arguments):
    root, output = Path(arguments[0]), Path(arguments[1])
    shards = arguments[2].split(",")
    receipts = load_receipts(root)
    errors, summary = assess(receipts, shards)
    output.mkdir(parents=True, exist_ok=True)
    (output / "qualification.json").write_text(json.dumps(
        {"runs_per_shard": RUNS_PER_SHARD, "cold_runs": COLD_RUNS, "summary": summary,
         "errors": errors, "receipts": receipts}, indent=2) + "\n", encoding="utf-8")
    report = markdown(receipts, summary, errors)
    (output / "qualification.md").write_text(report, encoding="utf-8")
    print(report)
    for error in errors:
        print(f"::error::{error}", file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
