"""Flake-gate decision for repeated launched-app qualification runs."""

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "summarise-core-journey-qualification.py"
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
