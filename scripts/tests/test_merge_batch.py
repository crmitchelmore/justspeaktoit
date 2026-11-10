"""Gate, evidence and parsing tests for scripts/merge-batch (no network)."""
import importlib.machinery
import importlib.util
import json
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
_loader = importlib.machinery.SourceFileLoader('merge_batch', str(ROOT / 'scripts' / 'merge-batch'))
_spec = importlib.util.spec_from_loader('merge_batch', _loader)
merge_batch = importlib.util.module_from_spec(_spec)
sys.modules['merge_batch'] = merge_batch
_loader.exec_module(merge_batch)
evidence = merge_batch.load_evidence()

REQUIRED = ['Build & Test (macOS)', 'Build iOS Library', 'Lint']


def check(name, status='completed', conclusion='success', started='2026-11-10T10:00:00Z', id_=1):
    return {'name': name, 'status': status, 'conclusion': conclusion, 'started_at': started, 'id': id_}


def green():
    return [check(name) for name in REQUIRED]


class GateTests(unittest.TestCase):
    def test_no_checks_registered_yet_is_pending_not_green(self):
        state, lines = merge_batch.evaluate_gate(REQUIRED, [], [], [])
        self.assertEqual(state, 'pending')
        self.assertIn('not reported yet', lines[0])

    def test_all_required_green_with_no_other_runs_is_success(self):
        self.assertEqual(merge_batch.evaluate_gate(REQUIRED, green(), [], [])[0], 'success')

    def test_missing_one_required_context_is_pending(self):
        self.assertEqual(merge_batch.evaluate_gate(REQUIRED, green()[:2], [], [])[0], 'pending')

    def test_required_failure_fails_even_while_others_run(self):
        runs = [check('Lint', conclusion='failure'), check('Build iOS Library', status='in_progress', conclusion=None)]
        self.assertEqual(merge_batch.evaluate_gate(REQUIRED, runs, [], [])[0], 'failure')

    def test_skipped_required_check_counts_as_passing(self):
        runs = green()[:2] + [check('Lint', conclusion='skipped')]
        self.assertEqual(merge_batch.evaluate_gate(REQUIRED, runs, [], [])[0], 'success')

    def test_rerun_replaces_the_earlier_attempt(self):
        runs = green() + [check('Lint', conclusion='failure', started='2026-11-10T09:00:00Z', id_=0)]
        self.assertEqual(merge_batch.evaluate_gate(REQUIRED, runs, [], [])[0], 'success')

    def test_commit_status_can_satisfy_a_required_context(self):
        statuses = [{'context': 'Lint', 'state': 'success', 'updated_at': 'x'}]
        self.assertEqual(merge_batch.evaluate_gate(REQUIRED, green()[:2], statuses, [])[0], 'success')

    def test_other_workflows_block_unless_ignored(self):
        windows = {'name': 'Windows ARM64', 'status': 'queued', 'conclusion': None, 'created_at': 'a', 'id': 1}
        tessl = {'name': 'Tessl Code Review', 'status': 'completed', 'conclusion': 'failure', 'created_at': 'a', 'id': 2}
        self.assertEqual(merge_batch.evaluate_gate(REQUIRED, green(), [], [windows, tessl])[0], 'pending')
        self.assertEqual(merge_batch.evaluate_gate(REQUIRED, green(), [], [tessl])[0], 'success')

    def test_no_required_contexts_never_passes(self):
        self.assertEqual(merge_batch.evaluate_gate([], [], [], [])[0], 'pending')

    def test_required_contexts_come_from_the_ruleset(self):
        rules = [{'type': 'pull_request'}, {'type': 'required_status_checks', 'parameters': {
            'required_status_checks': [{'context': 'Lint'}, {'context': 'Build iOS Library'}]}}]
        self.assertEqual(merge_batch.required_contexts(rules), ['Build iOS Library', 'Lint'])

    def test_wait_polls_until_the_gate_settles(self):
        states = iter(['pending', 'pending', 'success'])
        sleeps = []
        state, _ = merge_batch.wait_for_gate('a' * 40, REQUIRED, timeout_minutes=60,
                                             probe=lambda *_: (next(states), []), sleep=sleeps.append)
        self.assertEqual((state, len(sleeps)), ('success', 2))

    def test_wait_gives_up_at_the_timeout(self):
        state, _ = merge_batch.wait_for_gate('a' * 40, REQUIRED, timeout_minutes=0,
                                             probe=lambda *_: ('pending', []), sleep=lambda _: None)
        self.assertEqual(state, 'pending')


class EvidenceTests(unittest.TestCase):
    batch = 'b' * 40

    def records(self, *levels):
        return [{'pr': 10 + i, 'head': f'{i}' * 40, 'evidence': level, 'message': 'm'} for i, level in enumerate(levels)]

    def test_batch_record_is_accepted_by_the_evidence_check_at_the_batch_head(self):
        body = 'Intro\n\n' + merge_batch.evidence_block(self.batch, self.records('ok', 'warning'))
        self.assertEqual(evidence.evaluate(body, self.batch, 'crmitchelmore')[0], 'ok')

    def test_member_without_evidence_fails_the_batch_record(self):
        body = merge_batch.evidence_block(self.batch, self.records('ok', 'error'))
        self.assertEqual(evidence.evaluate(body, self.batch, 'crmitchelmore')[0], 'error')

    def test_marker_lists_members(self):
        body = merge_batch.evidence_block(self.batch, self.records('ok'))
        marker = json.loads(body.split('<!-- pre-pr-summary ')[1].split(' -->')[0])
        self.assertEqual(marker['source'], 'merge-batch')
        self.assertEqual(marker['members'], [{'pr': 10, 'head': '0' * 40, 'evidence': 'ok'}])


class ParsingTests(unittest.TestCase):
    def test_members_are_read_from_hidden_markers(self):
        body = 'x\n<!-- merge-batch-member 12 abc123 -->\n<!-- merge-batch-member 7 def456 -->\n'
        self.assertEqual(merge_batch.members(body), [(12, 'abc123'), (7, 'def456')])

    def test_rank_prefers_user_visible_types(self):
        self.assertGreater(merge_batch.rank('feat(mac): x'), merge_batch.rank('fix: y'))
        self.assertGreater(merge_batch.rank('fix: y'), merge_batch.rank('ci: z'))
        self.assertEqual(merge_batch.rank('Merge stuff'), 0)

    def test_usage_error_exits_64(self):
        self.assertEqual(merge_batch.main(['land']), 64)
        self.assertEqual(merge_batch.main(['status', 'x', '--bogus']), 64)


if __name__ == '__main__':
    unittest.main()
