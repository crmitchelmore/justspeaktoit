"""Truth-table tests for scripts/ci/pre_pr_outcome.py, scripts/pre-pr's outcome classifier."""
import importlib.util
import sys
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / 'ci' / 'pre_pr_outcome.py'
_spec = importlib.util.spec_from_file_location('pre_pr_outcome', SCRIPT)
outcome = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = outcome
_spec.loader.exec_module(outcome)
Outcome = outcome.Outcome


def launch(skip_reason='', failure='', missing_tool=None, advisory=False):
    return outcome.before_launch(skip_reason=skip_reason, failure=failure, missing_tool=missing_tool,
                                 advisory=advisory)


def ran(exit_code=0, tests_executed=None, drifted=(), advisory=False):
    return outcome.after_exit(advisory=advisory, exit_code=exit_code, tests_executed=tests_executed,
                              drifted=drifted, log='L')


class BeforeLaunchTests(unittest.TestCase):
    def test_a_runnable_check_is_not_settled(self):
        self.assertIsNone(launch())

    def test_planned_skip_wins_over_everything(self):
        self.assertEqual(launch('macOS only', 'boom', 'tool'), Outcome('skip', 'macOS only'))

    def test_planning_failure_fails_even_when_advisory(self):
        self.assertEqual(launch(failure='nothing selected', advisory=True), Outcome('fail', 'nothing selected'))

    def test_missing_tool_fails_closed_unless_advisory(self):
        self.assertEqual(launch(missing_tool='actionlint'), Outcome('fail', 'actionlint not installed'))
        self.assertEqual(launch(missing_tool='actionlint', advisory=True), Outcome('warn', 'actionlint not installed'))

    def test_unstartable_command_fails_closed_unless_advisory(self):
        self.assertEqual(outcome.cannot_start(advisory=False, reason='No such file'),
                         Outcome('fail', 'cannot start: No such file'))
        self.assertEqual(outcome.cannot_start(advisory=True, reason='x').status, 'warn')


class AfterExitTests(unittest.TestCase):
    def test_clean_exit_passes(self):
        self.assertEqual(ran(), Outcome('pass'))
        self.assertEqual(ran(tests_executed=5), Outcome('pass', '5 tests'))

    def test_non_zero_exit_fails_unless_advisory(self):
        self.assertEqual(ran(2), Outcome('fail', 'exit 2; log L'))
        self.assertEqual(ran(2, advisory=True), Outcome('warn', 'exit 2; log L'))

    def test_non_zero_exit_wins_over_zero_tests_and_drift(self):
        self.assertEqual(ran(1, tests_executed=0, drifted=['P']).note, 'exit 1; log L')

    def test_zero_tests_fails_even_when_advisory(self):
        self.assertEqual(ran(tests_executed=0, advisory=True), Outcome('fail', 'no tests matched the filter; log L'))

    def test_drift_fails_a_passing_check_and_names_the_files(self):
        result = ran(tests_executed=3, drifted={'b', 'a'})
        self.assertEqual(result.status, 'fail')
        self.assertTrue(result.note.startswith('modified a, b (CI fails on this drift)'))

    def test_not_run_after_a_failure_is_a_skip(self):
        self.assertEqual(outcome.not_run('earlier failure'), Outcome('skip', 'earlier failure'))


class RunResultTests(unittest.TestCase):
    def test_precedence_is_fail_then_incomplete_then_pass(self):
        cases = [
            ((['pass', 'warn', 'skip'], False), 'pass'),
            (([], False), 'pass'),
            ((['pass', 'skip'], True), 'incomplete'),
            ((['pass', 'fail'], True), 'fail'),
            ((['warn'], False), 'pass'),
        ]
        for (statuses, incomplete), expected in cases:
            with self.subTest(statuses=statuses, incomplete=incomplete):
                self.assertEqual(outcome.run_result(iter(statuses), incomplete), expected)

    def test_only_pass_exits_zero(self):
        self.assertEqual([outcome.exit_status(r) for r in ('pass', 'incomplete', 'fail')], [0, 1, 1])


if __name__ == '__main__':
    unittest.main()
