"""Planner and summary tests for scripts/pre-pr."""
import importlib.machinery
import importlib.util
import json
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
_loader = importlib.machinery.SourceFileLoader('pre_pr', str(ROOT / 'scripts' / 'pre-pr'))
_spec = importlib.util.spec_from_loader('pre_pr', _loader)
pre_pr = importlib.util.module_from_spec(_spec)
sys.modules['pre_pr'] = pre_pr
_loader.exec_module(pre_pr)
_evidence_spec = importlib.util.spec_from_file_location('pre_pr_evidence', ROOT / 'scripts' / 'check-pre-pr-evidence.py')
evidence = importlib.util.module_from_spec(_evidence_spec)
_evidence_spec.loader.exec_module(evidence)


def ids(files, full=False):
    checks, areas = pre_pr.plan(files, full)
    return [c.id for c in checks], areas, checks


class PlanTests(unittest.TestCase):
    def test_docs_only_change_runs_nothing(self):
        selected, areas, _ = ids(['Docs/automation.md', 'README.md'])
        self.assertEqual(selected, [])
        self.assertEqual(areas, {})

    def test_tooling_change_mirrors_the_ci_lint_tooling_gate(self):
        selected, _, _ = ids(['scripts/release-train.mjs'])
        self.assertEqual(selected, ['tooling-tests'])

    def test_workflow_change_adds_actionlint(self):
        selected, _, _ = ids(['.github/workflows/ci.yml'])
        self.assertIn('actionlint', selected)
        self.assertIn('tooling-tests', selected)

    def test_android_worker_and_landing_are_independent_areas(self):
        selected, areas, _ = ids(['android/app/build.gradle.kts', 'workers/paid-access/src/index.ts',
                                  'landing-page/index.html'])
        self.assertEqual(set(areas), {'android', 'paid-access-worker', 'landing-page'})
        self.assertIn('android', selected)
        self.assertIn('worker-test', selected)
        self.assertIn('landing-tests', selected)
        self.assertNotIn('apple-build', selected)

    def test_shared_core_change_selects_apple_and_portable(self):
        _, areas, _ = ids(['Sources/SpeakCore/SecureStorage.swift'])
        self.assertIn('apple', areas)
        self.assertIn('portable', areas)

    def test_source_change_selects_matching_unit_tests(self):
        filters, _ = pre_pr.swift_test_filter(['Sources/SpeakCore/SecureStorage.swift'], False)
        self.assertTrue(filters)
        self.assertTrue(all('SecureStorage' in f for f in filters), filters)

    def test_full_mode_selects_whole_target(self):
        filters, _ = pre_pr.swift_test_filter(['Sources/SpeakCore/SecureStorage.swift'], True)
        self.assertEqual(filters, ['SpeakCoreTests'])

    def test_ui_test_targets_are_never_selected(self):
        changes = ['Tests/SpeakAppUITests/CoreJourneyUITests.swift', 'Tests/SpeakiOSUITests/LaunchTests.swift']
        for full in (False, True):
            filters, skipped = pre_pr.swift_test_filter(changes, full)
            self.assertEqual(filters, [])
            self.assertEqual(skipped, ['SpeakAppUITests', 'SpeakiOSUITests'])

    def test_no_check_drives_ui_or_launches_the_app(self):
        everything = ['Package.swift', 'Project.swift', 'Sources/SpeakApp/AppDelegate.swift',
                      'Tests/SpeakAppTests/HistoryTests.swift', 'Tests/SpeakAppUITests/X.swift',
                      'Sources/SpeakWindows/App.swift', 'scripts/run-core-journey-e2e.sh',
                      '.github/workflows/ci.yml', 'android/app/x.kt', 'workers/paid-access/a.ts',
                      'landing-page/a.html']
        for full in (False, True):
            _, _, checks = ids(everything, full)
            for check in checks:
                if check.id in {'shellcheck', 'swiftlint', 'swiftformat'}:
                    continue  # static linters only read the named files
                command = ' '.join(check.command)
                for forbidden in ('xcodebuild', 'UITests', 'core-journey', 'verify-launch', 'preflight',
                                  'swift run', 'open ', 'osascript', 'connectedAndroidTest'):
                    self.assertNotIn(forbidden, command, check.id)

    def test_swift_tests_use_the_private_keychain_and_separate_scratch(self):
        _, _, checks = ids(['Tests/SpeakAppTests/HistoryTests.swift'])
        by_id = {c.id: c for c in checks}
        if 'apple-unit-tests' not in by_id:
            self.skipTest('Swift unit tests are planned only on macOS')
        for check in (by_id['apple-build'], by_id['apple-unit-tests']):
            self.assertEqual(check.env['JSTI_TEST_KEYCHAIN'], '1')
            self.assertEqual(check.env['JSTI_TEST_KEYCHAIN_REDIRECT'], '1')
            self.assertIn('--scratch-path', check.command)
        self.assertIn('scripts/with-test-keychain.py', by_id['apple-unit-tests'].command)

    def test_markdown_carries_a_machine_readable_marker(self):
        summary = {'schema': 1, 'head': 'a' * 40, 'dirty': False, 'base_ref': 'origin/main',
                   'merge_base': 'b' * 40, 'changed_file_count': 1, 'duration_seconds': 3.0, 'result': 'pass',
                   'checks': [{'title': 'x', 'area': 'tooling', 'status': 'pass', 'note': '',
                               'duration_seconds': 3.0}]}
        text = pre_pr.markdown(summary)
        marker = text.split('<!-- pre-pr-summary ')[1].split(' -->')[0]
        self.assertEqual(json.loads(marker), {'schema': 1, 'head': 'a' * 40, 'result': 'pass'})


class EvidenceTests(unittest.TestCase):
    head = 'c' * 40

    def body(self, result='pass', head=None):
        summary = {'schema': 1, 'head': head or self.head, 'dirty': False, 'base_ref': 'origin/main',
                   'merge_base': 'b' * 40, 'changed_file_count': 1, 'duration_seconds': 1.0, 'result': result,
                   'checks': []}
        return 'Intro\n\n' + pre_pr.markdown(summary)

    def test_generated_passing_record_at_head_is_accepted(self):
        self.assertEqual(evidence.evaluate(self.body(), self.head, 'crmitchelmore')[0], 'ok')

    def test_missing_and_failing_records_are_errors(self):
        self.assertEqual(evidence.evaluate('No evidence', self.head, 'crmitchelmore')[0], 'error')
        self.assertEqual(evidence.evaluate(self.body('fail'), self.head, 'crmitchelmore')[0], 'error')

    def test_stale_record_is_a_warning(self):
        self.assertEqual(evidence.evaluate(self.body(head='d' * 40), self.head, 'crmitchelmore')[0], 'warning')

    def test_bots_are_exempt(self):
        for bot in ('dependabot[bot]', 'devin-ai-integration[bot]', 'Copilot[bot]'):
            self.assertEqual(evidence.evaluate('', self.head, bot)[0], 'ok', bot)


if __name__ == '__main__':
    unittest.main()
