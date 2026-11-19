"""Flake-gate decision for repeated launched-app qualification runs."""

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "core-journey/summarise-core-journey-qualification.py"
SPEC = importlib.util.spec_from_file_location("journey_qualification", SCRIPT)
qualification = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(qualification)


def receipts(shard="p0", runners=5, iterations=4, overrides=None):
    rows = []
    for runner in range(1, runners + 1):
        for iteration in range(1, iterations + 1):
            row = {"shard": shard, "runner": runner, "iteration": iteration, "cold": iteration == 1,
                   "exit_code": 0, "coverage_errors": [], "seconds": 300 + runner + iteration}
            row.update((overrides or {}).get((runner, iteration), {}))
            rows.append(row)
    return rows


class QualificationTests(unittest.TestCase):
    def test_twenty_clean_runs_with_five_cold_qualify(self):
        errors, summary = qualification.assess(receipts(), ["p0"])
        self.assertEqual(errors, [])
        self.assertEqual(summary["p0"]["runs"], 20)
        self.assertEqual(summary["p0"]["cold_passed"], 5)
        self.assertEqual(summary["p0"]["max_seconds"], 309)

    def test_any_failure_or_coverage_error_disqualifies(self):
        for override in ({"exit_code": 1}, {"coverage_errors": ["missing case"]}):
            errors, _ = qualification.assess(receipts(overrides={(3, 2): override}), ["p0"])
            self.assertTrue(errors, override)

    def test_missing_shard_runs_or_cold_runs_disqualify(self):
        self.assertTrue(qualification.assess(receipts(runners=4), ["p0"])[0])
        self.assertTrue(qualification.assess(receipts(), ["p0", "foundation"])[0])
        rows = receipts(runners=1, iterations=20)
        self.assertTrue(any("cold" in error for error in qualification.assess(rows, ["p0"])[0]))

    def test_a_retried_iteration_is_not_admissible(self):
        rows = receipts()
        rows[-1] = dict(rows[0])
        errors, _ = qualification.assess(rows, ["p0"])
        self.assertTrue(any("retry" in error for error in errors))

    def test_jobs_that_never_tested_may_qualify_from_a_later_attempt(self):
        # Runners 2 and 4 failed setup in attempt 1 (no receipts); a rerun supplies them.
        rows = [dict(r, run_attempt=2 if r["runner"] in (2, 4) else 1, sha="abc") for r in receipts()]
        errors, summary = qualification.assess(rows, ["p0"])
        self.assertEqual(errors, [])
        self.assertEqual((summary["p0"]["runs"], summary["p0"]["cold_passed"]), (20, 5))

    def test_a_job_that_tested_in_two_attempts_is_a_retry(self):
        # Runner 3 failed iteration 2 in attempt 1, then passed all four in attempt 2.
        rows = [dict(r, run_attempt=1) for r in receipts() if r["runner"] != 3]
        rows += [dict(r, run_attempt=1, exit_code=r["iteration"] - 1)
                 for r in receipts() if r["runner"] == 3 and r["iteration"] <= 2]
        rows += [dict(r, run_attempt=2) for r in receipts() if r["runner"] == 3]
        errors, _ = qualification.assess(rows, ["p0"])
        self.assertTrue(any("retry after testing" in error for error in errors))
        self.assertTrue(any("iteration 2 failed" in error for error in errors))

    def test_setup_failed_or_incomplete_jobs_never_count(self):
        # Runner 5 failed setup and was not rerun; runner 1's rerun stopped after two iterations.
        rows = [r for r in receipts() if r["runner"] != 5]
        rows = [dict(r, run_attempt=2) if r["runner"] == 1 else r for r in rows if r["runner"] != 1 or r["iteration"] <= 2]
        errors, summary = qualification.assess(rows, ["p0"])
        self.assertEqual(summary["p0"]["runs"], 14)
        self.assertTrue(any("expected 20 executions" in error for error in errors))
        self.assertTrue(any("cold" in error for error in errors))

    def test_receipts_from_different_revisions_disqualify(self):
        rows = [dict(r, sha="new" if r["runner"] == 5 else "old") for r in receipts()]
        self.assertTrue(any("source revision" in e for e in qualification.assess(rows, ["p0"])[0]))

    def test_main_writes_receipts_and_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "in"
            for index, row in enumerate(receipts(overrides={(1, 1): {"exit_code": 65}})):
                path = root / str(index) / "iteration.json"
                path.parent.mkdir(parents=True)
                path.write_text(json.dumps(row))
            out = Path(directory) / "out"
            self.assertEqual(qualification.main([str(root), str(out), "p0"]), 1)
            result = json.loads((out / "qualification.json").read_text())
            self.assertEqual(len(result["receipts"]), 20)
            self.assertIn("NOT qualified", (out / "qualification.md").read_text())


if __name__ == "__main__":
    unittest.main()
