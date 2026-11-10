"""Offline tests for scripts/ci-metrics: run cache, zombies, critical path and the scorecard."""
import argparse
import datetime as dt
import importlib.machinery
import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
_loader = importlib.machinery.SourceFileLoader('ci_metrics', str(ROOT / 'scripts' / 'ci-metrics'))
_spec = importlib.util.spec_from_loader('ci_metrics', _loader)
ci_metrics = importlib.util.module_from_spec(_spec)
sys.modules['ci_metrics'] = ci_metrics
_loader.exec_module(ci_metrics)

UTC = dt.timezone.utc


def run(id_, created='2026-11-01T10:00:00Z', status='completed', conclusion='success', event='pull_request',
        path='.github/workflows/ci.yml'):
    return {'id': id_, 'name': 'CI', 'path': path, 'event': event, 'status': status, 'conclusion': conclusion,
            'created_at': created, 'run_started_at': created, 'updated_at': '2026-11-01T11:00:00Z',
            'run_attempt': 1, 'head_branch': 'b', 'html_url': f'https://x/{id_}'}


def job(name, start, end, created='2026-11-01T10:00:00Z', runner='r1', conclusion='success', labels=('macos-15',)):
    return {'name': name, 'created_at': created, 'started_at': start, 'completed_at': end,
            'runner_name': runner, 'conclusion': conclusion, 'labels': list(labels)}


class CacheTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.cache = mock.patch.object(ci_metrics, 'CACHE', Path(self.tmp.name))
        self.cache.start()

    def tearDown(self):
        self.cache.stop()
        self.tmp.cleanup()

    def fetch(self, day, runs, today=dt.date(2026, 11, 10), refresh=False):
        calls = []

        def fake(path, paginate=False):
            calls.append(path)
            return [{'workflow_runs': runs}]
        with mock.patch.object(ci_metrics, 'gh_api', fake):
            return ci_metrics.day_runs(day, refresh, today), calls

    def test_settled_day_is_served_from_the_cache(self):
        first, calls = self.fetch(dt.date(2026, 11, 1), [run(1)])
        again, calls_again = self.fetch(dt.date(2026, 11, 1), [run(2)])
        self.assertEqual((len(calls), calls_again), (1, []))
        self.assertEqual(again, first)
        self.assertNotIn('labels', again[0])  # only report fields are kept

    def test_recent_or_unfinished_days_are_always_refetched(self):
        self.fetch(dt.date(2026, 11, 9), [run(1)])
        self.assertEqual(len(self.fetch(dt.date(2026, 11, 9), [run(1)])[1]), 1)
        self.fetch(dt.date(2026, 11, 1), [run(1, status='queued', conclusion=None)])
        self.assertEqual(len(self.fetch(dt.date(2026, 11, 1), [run(1)])[1]), 1)

    def test_refresh_bypasses_the_cache(self):
        self.fetch(dt.date(2026, 11, 1), [run(1)])
        self.assertEqual(len(self.fetch(dt.date(2026, 11, 1), [run(2)], refresh=True)[1]), 1)


class ZombieTests(unittest.TestCase):
    def test_only_unfinished_runs_older_than_a_day_are_zombies(self):
        now = dt.datetime(2026, 11, 10, 12, tzinfo=UTC)
        runs = [run(1, '2026-10-07T00:00:00Z', 'queued', None), run(2, '2026-11-10T00:00:00Z', 'queued', None),
                run(3, '2026-11-01T00:00:00Z', 'in_progress', None), run(4, '2026-10-01T00:00:00Z')]
        found = ci_metrics.zombies(runs, now)
        self.assertEqual([z['id'] for z in found], [1, 3])
        self.assertEqual(found[0]['workflow'], 'ci.yml')
        self.assertGreater(found[0]['age_hours'], 24 * 30)


class CriticalPathTests(unittest.TestCase):
    def test_last_substantive_job_ends_the_path_and_unstarted_jobs_are_ignored(self):
        jobs = [
            job('Lint', '2026-11-01T10:01:00Z', '2026-11-01T10:10:00Z'),
            job('Build iOS Library', '2026-11-01T10:30:00Z', '2026-11-01T10:50:00Z'),
            job('Gate', '2026-11-01T10:50:10Z', '2026-11-01T10:50:20Z'),  # aggregate, seconds long
            job('Cancelled', '2026-11-01T10:00:00Z', '2026-11-01T11:30:00Z', runner=''),
        ]
        table = {row['job']: row for row in ci_metrics.critical_path([(run(1), jobs)])}
        self.assertNotIn('Cancelled', table)
        self.assertEqual(table['Build iOS Library']['last_to_finish'], 1)
        self.assertEqual(table['Gate']['last_to_finish'], 0)
        self.assertAlmostEqual(table['Build iOS Library']['queue_p50'], 30.0)
        self.assertAlmostEqual(table['Build iOS Library']['finish_p50'], 50.0)


class EscapeTests(unittest.TestCase):
    def marker(self, head, result='pass', tree=None):
        record = {'schema': 1, 'head': head, 'result': result, **({'tree': tree} if tree else {})}
        return 'x\n<!-- pre-pr-summary ' + __import__('json').dumps(record) + ' -->'

    def test_only_failures_with_passing_evidence_for_that_head_escape(self):
        def failure(id_, sha, event='pull_request', branch='b'):
            return {**run(id_, conclusion='failure', event=event), 'head_sha': sha, 'head_branch': branch,
                    'pull_requests': [id_] if event == 'pull_request' else []}
        runs = [failure(1, 'a' * 40), failure(2, 'b' * 40), failure(3, 'c' * 40), failure(4, 'd' * 40),
                failure(5, 'e' * 40, 'push', 'merge-batch/7'), failure(6, 'f' * 40, 'push', 'main'),
                {**run(7), 'head_sha': 'g' * 40, 'pull_requests': [7]}]
        bodies = {1: self.marker('a' * 40), 2: self.marker('0' * 40), 3: '', 4: self.marker('0' * 40, tree='t4'),
                  50: self.marker('e' * 40, 'fail')}
        pr_for = lambda r: r['pull_requests'][0] if r['pull_requests'] else 50
        result = ci_metrics.escapes(runs, pr_for, lambda n: bodies.get(n, ''), lambda sha: 't4')
        self.assertEqual(result['gate_failures'], 5)  # main pushes and successes don't count
        self.assertEqual(result['escaped'], 2)  # exact head, and the same tree committed afterwards
        self.assertEqual(result['no_evidence'], 1)
        self.assertEqual(result['failing_or_stale_evidence'], 2)
        self.assertEqual(result['escape_rate'], 0.4)
        self.assertEqual([e['pr'] for e in result['escapes']], [1, 4])


class ComputeTests(unittest.TestCase):
    def test_scorecard_reports_merge_gate_and_main_rates(self):
        runs = [run(1), run(2, event='push', conclusion='failure'), run(3, event='push'),
                run(4, event='push', conclusion='cancelled'), run(5, conclusion='cancelled')]
        jobs = [job(name, '2026-11-01T10:05:00Z', '2026-11-01T10:40:00Z') for name in ci_metrics.REQUIRED_CHECKS]
        prs = [{'created_at': '2026-11-01T00:00:00Z', 'pull_request': {'merged_at': '2026-11-01T02:00:00Z'}}]
        args = argparse.Namespace(since=dt.date(2026, 11, 1), until=dt.date(2026, 11, 2), days=30,
                                  max_job_runs=10, refresh=False,
                                  escapes=lambda runs: ci_metrics.escapes(runs, lambda r: None, str, str),
                                  integration=lambda prs, runs, since, until: ci_metrics.integration(
                                      [], runs, {}.get, [], lambda a, b: False, 0,
                                      dt.datetime(2026, 11, 1, tzinfo=UTC), dt.datetime(2026, 11, 2, tzinfo=UTC)))
        with mock.patch.object(ci_metrics, 'list_runs', lambda *a: runs), \
                mock.patch.object(ci_metrics, 'list_merged_prs', lambda *a: prs), \
                mock.patch.object(ci_metrics, 'list_zombies', lambda: [{'id': 9, 'workflow': 'ci.yml', 'status': 'queued', 'branch': 'b', 'age_hours': 30.0, 'url': 'u'}]), \
                mock.patch.object(ci_metrics, 'run_jobs', lambda r: jobs):
            data = ci_metrics.compute(args)
        card = data['scorecard']
        self.assertEqual(card['pr_open_to_merge_hours_p50'], 2.0)
        self.assertEqual(card['required_gate_minutes_p50'], 40.0)
        self.assertEqual(card['main_failure_rate'], 0.5)
        self.assertEqual(round(card['main_cancel_rate'], 2), 0.33)
        self.assertEqual(card['zombie_runs'], 1)
        text = ci_metrics.render(data)
        self.assertIn('Main CI failure rate: 50.0%', text)
        self.assertIn('## CI critical path', text)
        self.assertIn('Pre-PR escape rate', text)
        self.assertIn('Broken Alphas', text)


def main_run(id_, conclusion, done, event='push', sha=None):
    return {'id': id_, 'event': event, 'head_branch': 'main', 'status': 'completed', 'conclusion': conclusion,
            'created_at': done, 'updated_at': done, 'head_sha': sha or f'sha{id_}'}


class IntegrationTests(unittest.TestCase):
    start = dt.datetime(2026, 11, 1, tzinfo=UTC)
    end = dt.datetime(2026, 11, 2, tzinfo=UTC)

    def test_main_is_red_from_a_failure_until_the_next_green_run(self):
        runs = [main_run(1, 'failure', '2026-11-01T10:00:00Z'), main_run(2, 'failure', '2026-11-01T10:30:00Z'),
                main_run(3, 'cancelled', '2026-11-01T10:40:00Z'),
                main_run(4, 'success', '2026-11-01T11:00:00Z', event='workflow_dispatch'),
                main_run(5, 'failure', '2026-11-01T23:30:00Z')]
        red = ci_metrics.main_red_minutes(runs, self.start, self.end)
        self.assertEqual(red['minutes'], 90)
        self.assertEqual(red['episodes'], 2)

    def test_ready_to_merged_starts_at_the_final_head_with_a_passing_record(self):
        record = '<!-- pre-pr-summary {"head": "h1", "result": "pass"} -->'
        prs = [{'number': 1, 'labels': [], 'pull_request': {'merged_at': '2026-11-01T10:07:00Z'}},
               {'number': 2, 'labels': [], 'pull_request': {'merged_at': '2026-11-01T12:00:00Z'}},
               {'number': 3, 'labels': [{'name': 'auto-revert'}], 'pull_request': {'merged_at': '2026-11-01T13:00:00Z'}}]
        details = {1: {'head': {'sha': 'h1'}, 'body': record}, 2: {'head': {'sha': 'h2'}, 'body': ''},
                   3: {'merge_commit_sha': 'r3', 'body': 'x\n\nAuto-revert-of: c1 c2\n'}}
        runs = [{'event': 'pull_request', 'head_sha': 'h1', 'created_at': '2026-11-01T10:00:00Z'},
                {'event': 'pull_request', 'head_sha': 'h1', 'created_at': '2026-11-01T10:03:00Z'}]
        flow = ci_metrics.integration(prs, runs, details.__getitem__, [], lambda a, b: False, 0, self.start, self.end)
        self.assertEqual(flow['ready_to_merged_minutes']['p50'], 7.0)
        self.assertEqual(flow['ready_to_merged_minutes']['without_record'], 1)
        self.assertEqual(flow['auto_reverts'], 1)

    def test_alpha_is_broken_by_its_own_red_ci_or_a_later_auto_revert(self):
        alphas = [{'tag': 'alpha-build-1', 'source': 'red'}, {'tag': 'alpha-build-2', 'source': 'carries'},
                  {'tag': 'alpha-build-3', 'source': 'fixed'}, {'tag': 'alpha-build-4', 'source': 'green'}]
        ancestry = {('c1', 'carries'), ('c1', 'fixed'), ('r', 'fixed')}
        result = ci_metrics.alpha_broken(alphas, {'red': 'failure', 'green': 'success'}.get,
                                         [{'merge': 'r', 'culprits': ['c1']}], lambda a, b: (a, b) in ancestry)
        self.assertEqual(result['broken_tags'], ['alpha-build-1', 'alpha-build-2'])
        self.assertEqual(result['rate'], 0.5)


if __name__ == '__main__':
    unittest.main()
