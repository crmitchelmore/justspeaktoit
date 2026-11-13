"""Planner and summary tests for scripts/pre-pr."""
import contextlib
import importlib.machinery
import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts' / 'ci'))
from pre_pr import environment, lock, mirror, planner, runner, swift_tests
from pre_pr import summary as record

_loader = importlib.machinery.SourceFileLoader('pre_pr_cli', str(ROOT / 'scripts' / 'pre-pr'))
_spec = importlib.util.spec_from_loader('pre_pr_cli', _loader)
cli = importlib.util.module_from_spec(_spec)
_loader.exec_module(cli)
_evidence_spec = importlib.util.spec_from_file_location('pre_pr_evidence', ROOT / 'scripts' / 'check-pre-pr-evidence.py')
evidence = importlib.util.module_from_spec(_evidence_spec)
_evidence_spec.loader.exec_module(evidence)


def ids(files, full=False):
    checks, areas = planner.plan(files, full)
    return [c.id for c in checks], areas, checks


class PlanTests(unittest.TestCase):
    def test_docs_only_change_runs_nothing(self):
        selected, areas, _ = ids(['Docs/automation.md', 'README.md'])
        self.assertEqual(selected, [])
        self.assertEqual(areas, {})

    def test_tooling_change_runs_the_ci_lint_job(self):
        selected, _, checks = ids(['scripts/release-train.mjs'])
        selected = [c for c in selected if c != 'ci-lint-linux']
        checks = [c for c in checks if c.id == 'ci-lint']
        self.assertEqual(selected, ['ci-lint'])
        self.assertEqual(checks[0].command, ['make', 'ci-lint'])
        self.assertEqual(checks[0].forbid_drift, ('Tooling/Package.resolved',))
        self.assertEqual(checks[0].env, {'JSTI_LINT_BASELINE_BASE': 'origin/main', 'JSTI_TEST_RETRY': '1'})

    def test_workflow_change_adds_the_required_quality_check(self):
        selected, _, checks = ids(['.github/workflows/ci.yml'])
        self.assertIn('ci-lint', selected)
        self.assertNotIn('portable-linux', selected)
        quality = next(c for c in checks if c.id == 'quality')
        self.assertEqual(quality.command, ['python3', 'scripts/quality', 'check', '.github/workflows/ci.yml'])
        self.assertFalse(quality.advisory)

    def test_python_and_shell_scripts_are_quality_checked(self):
        _, _, checks = ids(['scripts/pre-pr', 'scripts/swiftlint.sh', 'scripts/ci/routing.py', 'Docs/x.md'])
        quality = next(c for c in checks if c.id == 'quality')
        self.assertEqual(quality.command[3:], ['scripts/ci/routing.py', 'scripts/pre-pr', 'scripts/swiftlint.sh'])

    def test_autofix_lists_its_edits_and_fails_only_when_asked(self):
        def fake_finish(check, process, verbose, restore=True):
            self.assertFalse(restore)
            check.status = 'pass'

        for fail_on_fix, expected in ((False, 'pass'), (True, 'fail')):
            args = mock.Mock(no_fix=False, fail_on_fix=fail_on_fix, verbose=False)
            with mock.patch.object(cli, 'worktree_tree', side_effect=['before', 'after']), \
                    mock.patch.object(cli, 'launch'), mock.patch.object(cli, 'finish', fake_finish), \
                    mock.patch.object(cli, 'git', return_value='Sources/A.swift'), \
                    mock.patch('builtins.print'):
                check = cli.run_autofix(args, ['Package.swift'])
            self.assertEqual(check.status, expected)
            self.assertIn('fixed 1 file: Sources/A.swift', check.note)

    def test_android_runs_remotely_without_a_working_jdk_and_feed(self):
        with mock.patch.dict(os.environ, {'JSTI_ANDROID_LOCAL': '0'}):
            checks, _ = planner.plan(['android/app/build.gradle.kts'], False)
        android = {c.id: c for c in checks}['android']
        self.assertTrue(android.background)
        self.assertEqual(android.command[:4], ['python3', 'scripts/linux-precheck', '--job', 'android'])
        self.assertFalse(android.advisory or android.skip_reason or android.requires)
        with mock.patch.dict(os.environ, {'JSTI_ANDROID_LOCAL': '1'}):
            checks, _ = planner.plan(['android/app/build.gradle.kts'], False)
        self.assertEqual({c.id: c for c in checks}['android'].command, ['bash', 'scripts/ci-android.sh'])

    def test_macos_java_stub_is_not_a_jdk(self):
        failing = mock.Mock(returncode=1)
        with mock.patch.dict(os.environ, {'JSTI_MAVEN_MIRROR': 'https://feed'}), \
                mock.patch.object(subprocess, 'run', return_value=failing):
            os.environ.pop('JSTI_ANDROID_LOCAL', None)
            self.assertFalse(environment.android_runs_locally())

    def test_public_library_change_runs_the_api_compatibility_job(self):
        with mock.patch.object(environment, 'IS_MAC', True), mock.patch.object(environment, 'pr_title_env', lambda: {}):
            checks, areas = planner.plan(['Sources/SpeakCore/OpenRouter/Apple/OpenRouterAPIClient.swift'], False)
            api = {c.id: c for c in checks}['api-compatibility']
            self.assertEqual(api.command[:2], ['bash', 'scripts/ci-api-compatibility.sh'])
            self.assertEqual(api.command[2], environment.merge_base_or('origin/main'))
            # make ci-lint runs the gate's own tests, so the API job skips its copy of them.
            self.assertIn('ci-lint', {c.id for c in checks})
            self.assertEqual(api.env.get('JSTI_API_SELFTEST'), '0')
            self.assertTrue(api.mirror)
            self.assertIn('public-api', areas)
            for path in ('Sources/SpeakApp/AppDelegate.swift', 'Sources/SpeakDesktop/X.swift', 'Docs/x.md'):
                ids_ = [c.id for c in planner.plan([path], False)[0]]
                self.assertNotIn('api-compatibility', ids_, path)
        with mock.patch.object(environment, 'IS_MAC', False):
            api = {c.id: c for c in planner.plan(['Package.swift'], False)[0]}['api-compatibility']
        self.assertTrue(api.incomplete)

    def test_android_worker_and_landing_are_independent_areas(self):
        selected, areas, _ = ids(['android/app/build.gradle.kts', 'workers/paid-access/src/index.ts',
                                  'landing-page/index.html'])
        self.assertEqual(set(areas), {'android', 'paid-access-worker', 'landing-page'})
        self.assertIn('android', selected)
        self.assertIn('worker-test', selected)
        self.assertIn('landing-tests', selected)
        self.assertNotIn('apple-build', selected)

    def test_swift_change_runs_every_ci_gate_job_with_linux_first(self):
        selected, areas, checks = ids(['Sources/SpeakCore/Credentials/Apple/SecureStorage.swift'])
        self.assertEqual(set(areas), {'ci-lint', 'swift', 'public-api'})
        self.assertEqual(selected[0], 'portable-linux')
        self.assertTrue(checks[0].background)
        self.assertIn('scripts/linux-precheck', checks[0].command)
        self.assertIn('ci-lint', selected)
        if environment.IS_MAC:
            self.assertIn('apple-build', selected)
            self.assertEqual({c.id: c for c in checks}['apple-build'].forbid_drift, ('Package.resolved',))

    def test_lint_also_runs_on_ubuntu_like_ci(self):
        with mock.patch.object(sys, 'platform', 'darwin'):
            checks = {c.id: c for c in planner.plan(['scripts/release-train.mjs'], False)[0]}
            self.assertEqual(checks['ci-lint-linux'].command[2:4], ['--job', 'lint'])
            self.assertTrue(checks['ci-lint-linux'].background)
            skipped = {c.id: c for c in planner.plan(['scripts/release-train.mjs'], False, linux='skip')[0]}
            self.assertTrue(skipped['ci-lint-linux'].incomplete)
        with mock.patch.object(sys, 'platform', 'linux'):
            ids_ = [c.id for c in planner.plan(['scripts/release-train.mjs'], False)[0]]
        self.assertNotIn('ci-lint-linux', ids_)

    def test_linux_modes(self):
        for mode, flag in (('remote', '--remote'), ('container', '--container')):
            checks, _ = planner.plan(['Package.swift'], False, linux=mode)
            self.assertIn(flag, checks[0].command)
        checks, _ = planner.plan(['Package.swift'], False, linux='skip')
        linux = {c.id: c for c in checks}['portable-linux']
        self.assertTrue(linux.incomplete)
        self.assertEqual(linux.skip_reason, '--no-linux')

    def test_no_check_drives_ui_or_launches_the_app(self):
        everything = ['Package.swift', 'Project.swift', 'Sources/SpeakApp/AppDelegate.swift',
                      'Tests/SpeakAppTests/HistoryTests.swift', 'Tests/SpeakAppUITests/X.swift',
                      'Sources/SpeakWindows/App.swift', 'scripts/core-journey/run-core-journey-e2e.sh',
                      '.github/workflows/ci.yml', 'android/app/x.kt', 'workers/paid-access/a.ts',
                      'landing-page/a.html']
        for full in (False, True):
            _, _, checks = ids(everything, full)
            for check in checks:
                if check.id == 'quality':
                    continue  # static linters only read the named files
                command = ' '.join(check.command)
                for forbidden in ('xcodebuild', 'UITests', 'core-journey', 'verify-launch', 'preflight',
                                  'swift run', 'open ', 'osascript', 'connectedAndroidTest'):
                    self.assertNotIn(forbidden, command, check.id)

    def test_swift_tests_use_the_private_keychain_and_separate_scratch(self):
        _, _, checks = ids(['Tests/SpeakAppTests/AccessibilityRecoveryTests.swift'])
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
        text = record.markdown(summary)
        marker = text.split('<!-- pre-pr-summary ')[1].split(' -->')[0]
        self.assertEqual(json.loads(marker), {'schema': 1, 'head': 'a' * 40, 'result': 'pass'})
        summary['tree'] = 'c' * 40
        marker = record.markdown(summary).split('<!-- pre-pr-summary ')[1].split(' -->')[0]
        self.assertEqual(json.loads(marker)['tree'], 'c' * 40)

    def test_worktree_tree_matches_a_clean_head(self):
        if environment.git('status', '--porcelain'):
            self.skipTest('only comparable on a clean checkout')
        self.assertEqual(environment.worktree_tree(), environment.git('rev-parse', 'HEAD^{tree}'))


class CIParityTests(unittest.TestCase):
    """pre-pr must run CI's commands. Path routing is shared through scripts/ci/routing.json (test_ci_routing)."""

    ci = (ROOT / '.github' / 'workflows' / 'ci.yml').read_text(encoding='utf-8')
    # ci.yml's macOS Debug lane, which runs the affected unit tests.
    macos = (ROOT / '.github' / 'workflows' / 'ci-macos-debug.yml').read_text(encoding='utf-8')

    def test_macos_skip_targets_match_ci(self):
        self.assertEqual(set(re.findall(r'--skip-target (\w+)', self.macos)), swift_tests.CI_MACOS_SKIP_TARGETS)

    def test_android_command_matches_android_yml(self):
        android = (ROOT / '.github' / 'workflows' / 'android.yml').read_text(encoding='utf-8')
        self.assertIn('run: ../scripts/ci-android.sh', android)
        precheck = (ROOT / '.github' / 'workflows' / 'precheck.yml').read_text(encoding='utf-8')
        self.assertIn('run: scripts/ci-android.sh', precheck)
        for action in re.findall(r'uses: (actions/setup-java@\S+|gradle/actions/setup-gradle@\S+)', android):
            self.assertIn(action, precheck)

    def test_plan_needs_no_history(self):
        # CI's Lint job runs these tests in a shallow checkout without origin/main.
        with mock.patch.object(environment, 'IS_MAC', True), mock.patch.object(environment, 'pr_title_env', lambda: {}):
            checks, _ = planner.plan(['Package.swift'], False, base='no-such-ref/main')
        self.assertEqual({c.id: c for c in checks}['api-compatibility'].command[2], 'no-such-ref/main')

    def test_api_products_match_the_gate(self):
        gate = (ROOT / 'scripts' / 'ci' / 'check-api-compatibility.sh').read_text(encoding='utf-8')
        products = set(re.search(r'PRODUCTS=\(([^)]*)\)', gate).group(1).split()) | {'SpeakWatchCore'}
        dirs = {'SpeakiOSLib': 'SpeakiOS'}
        for product in products:
            self.assertIn(f'Sources/{dirs.get(product, product)}/**', environment.routing().routes()['api']['paths'],
                          product)

    def test_linux_image_is_the_ci_image(self):
        image = re.search(r'image: (swift:[^\s]+)', self.ci.split('Portable Swift (Linux)', 1)[1]).group(1)
        precheck = (ROOT / '.github' / 'workflows' / 'precheck.yml').read_text(encoding='utf-8')
        self.assertIn(f'image: {image}', precheck)
        self.assertIn(image, (ROOT / 'scripts' / 'linux-precheck').read_text(encoding='utf-8'))
        self.assertIn('scripts/ci-portable-linux.sh', precheck)


def fake_graph():
    return swift_tests.Graph.from_dump({'targets': [
        {'name': 'Core', 'type': 'regular', 'dependencies': []},
        {'name': 'App', 'type': 'executable', 'dependencies': [{'byName': ['Core', None]}]},
        {'name': 'Demo', 'type': 'executable', 'dependencies': [{'byName': ['Core', None]}]},
        {'name': 'Other', 'type': 'regular', 'dependencies': []},
        {'name': 'CoreTests', 'type': 'test', 'dependencies': [{'byName': ['Core', None]}]},
        {'name': 'AppTests', 'type': 'test', 'dependencies': [{'target': ['App', None]}]},
        {'name': 'OtherTests', 'type': 'test', 'dependencies': [{'byName': ['Other', None]}]},
    ]})


class SelectionTests(unittest.TestCase):
    """Unit-test selection over a fake SwiftPM graph, so no Swift toolchain is needed."""

    FILES = {
        'Sources/Core/Widget.swift': 'public struct Widget {}\nextension Gadget {}\nprivate struct Hidden {}\n',
        'Sources/Core/Gadget.swift': 'final class Gadget {}\n',
        'Sources/Core/Helpers.swift': 'func helper() {}\n',
        'Sources/App/AppView.swift': 'struct AppView {}\n',
        'Sources/Demo/main.swift': 'print(1)\n',
        'Tests/CoreTests/BehaviourTests.swift': 'final class BehaviourTests: XCTestCase { let w = Widget() }\n',
        'Tests/CoreTests/GadgetCases.swift': '@MainActor\nfinal class GadgetCases: XCTestCase { let g = Gadget() }\n',
        'Tests/CoreTests/UnrelatedTests.swift': 'struct UnrelatedTests { let h = Hidden() }\n',
        'Tests/AppTests/WidgetUseTests.swift': 'class WidgetUseTests: XCTestCase { let w: Widget? = nil }\n',
        'Tests/AppTests/AppViewTests.swift': 'class AppViewTests: XCTestCase {}\n',
        'Tests/OtherTests/OtherTests.swift': 'class OtherTests: XCTestCase { let w = "Widget" }\n',
        'Sources/Core/Core.swift': 'public enum Core {}\n',
        'Tests/CoreTests/BehaviourTests+More.swift': 'extension BehaviourTests { func testMore() {} }\n',
        'Tests/CoreTests/ImportOnlyTests.swift': '@testable import Core\n// Core\nfinal class ImportOnlyTests {}\n',
        'Tests/CoreTests/Plus+Cases.swift': 'func helper() {}\n',
        'Sources/Core/Billable.swift': 'struct Billable {}\n',
        'Tests/CoreTests/BillableIntegrationTests.swift':
            '#if JSTI_BILLABLE_INTEGRATION\nfinal class BillableIntegrationTests { let b = Billable() }\n#endif\n',
    }

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        for path, text in self.FILES.items():
            (self.root / path).parent.mkdir(parents=True, exist_ok=True)
            (self.root / path).write_text(text)
        self.graph = fake_graph()

    def tearDown(self):
        self.tmp.cleanup()

    def select(self, files, full=False, exclude=frozenset()):
        return swift_tests.select_tests(files, full, self.graph, set(exclude), root=self.root)

    def test_source_change_runs_every_dependent_test_that_names_its_types(self):
        selection = self.select(['Sources/Core/Widget.swift'])
        self.assertEqual(selection.filters, ['AppTests\\.(?:WidgetUseTests)\\b',
                                             'CoreTests\\.(?:BehaviourTests|GadgetCases)\\b'])
        # OtherTests mentions "Widget" but cannot import Core; private types are never matched.
        self.assertEqual(selection.targets, {'AppTests', 'CoreTests'})

    def test_unmatched_source_change_falls_back_to_the_module_test_target(self):
        self.assertEqual(self.select(['Sources/Core/Helpers.swift']).filters, ['CoreTests\\.'])

    def test_unmatched_module_without_own_target_runs_every_covering_target(self):
        self.assertEqual(self.select(['Sources/Demo/main.swift']).filters, [])  # nothing covers Demo
        self.assertEqual(swift_tests.uncovered_modules(['Sources/Demo/main.swift'], [self.graph]), ['Demo'])
        self.assertEqual(swift_tests.uncovered_modules(['Sources/Core/Helpers.swift'], [self.graph]), [])

    def test_name_matched_test_file_is_selected_even_without_a_reference(self):
        self.assertEqual(self.select(['Sources/App/AppView.swift']).filters, ['AppTests\\.(?:AppViewTests)\\b'])

    def test_changed_test_file_runs_its_declared_types(self):
        self.assertEqual(self.select(['Tests/CoreTests/GadgetCases.swift']).filters, ['CoreTests\\.(?:GadgetCases)\\b'])

    def test_extension_only_test_file_runs_the_extended_type(self):
        self.assertEqual(self.select(['Tests/CoreTests/BehaviourTests+More.swift']).filters,
                         ['CoreTests\\.(?:BehaviourTests)\\b'])

    def test_stem_fallback_is_escaped(self):
        self.assertEqual(self.select(['Tests/CoreTests/Plus+Cases.swift']).filters, ['CoreTests\\.(?:Plus)\\b'])

    def test_imports_and_comments_do_not_count_as_references(self):
        # Core.swift declares `enum Core`; `@testable import Core` and comments must not select every test.
        self.assertEqual(self.select(['Sources/Core/Core.swift']).filters, ['CoreTests\\.'])

    def test_opt_in_integration_files_are_never_selected(self):
        self.assertEqual(self.select(['Tests/CoreTests/BillableIntegrationTests.swift']).filters, [])
        # Only an opt-in file names Billable, so its module's test target runs instead.
        self.assertEqual(self.select(['Sources/Core/Billable.swift']).filters, ['CoreTests\\.'])

    def test_full_mode_runs_whole_covering_targets(self):
        self.assertEqual(self.select(['Sources/Core/Helpers.swift'], full=True).filters,
                         ['AppTests\\.', 'CoreTests\\.'])

    def test_excluded_targets_are_not_rerun_or_used_as_a_fallback(self):
        self.assertEqual(self.select(['Sources/Core/Helpers.swift'], exclude={'CoreTests'}).filters, [])

    def test_files_outside_the_graph_select_nothing(self):
        self.assertEqual(self.select(['Sources/Windows/App.swift', 'Docs/x.md']).filters, [])
        self.assertEqual(swift_tests.uncovered_modules(['Sources/Windows/App.swift'], [self.graph]), [])

    def test_uncovered_module_adds_a_failing_check(self):
        with mock.patch.object(environment, 'IS_MAC', True), \
                mock.patch.object(swift_tests, 'load_graph', lambda portable: None if portable else self.graph), \
                mock.patch.object(environment, 'ROOT', self.root):
            checks, _ = planner.plan(['Sources/Demo/main.swift'], False)
        by_id = {c.id: c for c in checks}
        self.assertIn('Demo', by_id['swift-test-coverage'].failure)
        order = [c.id for c in checks]
        self.assertLess(order.index('swift-test-coverage'), order.index('apple-build'), 'cheap failures run first')

    def test_unreadable_graph_fails_closed(self):
        with mock.patch.object(environment, 'IS_MAC', True), mock.patch.object(swift_tests, 'load_graph', lambda _: None):
            checks, _ = planner.plan(['Sources/SpeakCore/Credentials/Apple/SecureStorage.swift'], False)
        self.assertTrue({c.id: c for c in checks}['apple-unit-tests'].failure)


class RunTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.out = mock.patch.object(environment, 'OUT', Path(self.tmp.name))
        self.out.start()

    def tearDown(self):
        self.out.stop()
        self.tmp.cleanup()

    def run_check(self, **kwargs):
        check = runner.Check('x', 'tooling', 'x', kwargs.pop('command', ['true']), **kwargs)
        with mock.patch.object(runner, 'restore_side_effects', lambda *_: None):
            runner.run(check, verbose=False)
        return check

    def test_missing_required_tool_fails(self):
        self.assertEqual(self.run_check(requires='no-such-tool-jsti').status, 'fail')

    def test_missing_advisory_tool_warns(self):
        self.assertEqual(self.run_check(requires='no-such-tool-jsti', advisory=True).status, 'warn')

    def test_unstartable_command_fails(self):
        self.assertEqual(self.run_check(command=['/no/such/binary']).status, 'fail')

    def test_planning_failure_fails_without_running(self):
        self.assertEqual(self.run_check(failure='nothing selected').status, 'fail')

    def test_test_run_that_executes_nothing_fails(self):
        check = self.run_check(command=['echo', 'Executed 0 tests, with 0 failures'], counts_tests=True)
        self.assertEqual(check.status, 'fail')
        check = self.run_check(command=['echo', 'Executed 3 tests\nTest run with 2 tests passed'], counts_tests=True)
        self.assertEqual((check.status, check.note), ('pass', '5 tests'))

    def test_modifying_a_ci_checked_file_fails(self):
        states = iter([set(), {'Package.resolved'}])
        with mock.patch.object(runner, 'dirty_tracked', lambda *_: next(states)):
            check = self.run_check(forbid_drift=('Package.resolved',))
        self.assertEqual(check.status, 'fail')
        self.assertIn('Package.resolved', check.note)

    def test_counts_both_test_frameworks(self):
        log = 'Executed 4 tests\nExecuted 12 tests, with 0 failures\n✔ Test run with 7 tests in 2 suites passed'
        self.assertEqual(runner.tests_executed(log), 19)
        self.assertEqual(runner.tests_executed('No matching test cases were run'), 0)

    def test_a_hung_exclusive_check_is_killed_with_its_children(self):
        pidfile = Path(self.tmp.name) / 'grandchild.pid'
        hang = ['sh', '-c', f'sleep 60 & echo $! > {pidfile}; wait']
        with mock.patch.dict(os.environ, {'JSTI_PRE_PR_CHECK_TIMEOUT': '1'}):
            started = time.monotonic()
            check = self.run_check(command=hang)
        self.assertLess(time.monotonic() - started, 20)
        self.assertEqual(check.status, 'fail')
        self.assertIn('timed out after 1s', check.note)
        with self.assertRaises(ProcessLookupError):
            os.kill(int(pidfile.read_text()), 0)

    def test_remote_checks_are_not_timed_out(self):
        with mock.patch.dict(os.environ, {'JSTI_PRE_PR_CHECK_TIMEOUT': '1'}):
            check = self.run_check(command=['sleep', '2'], exclusive=False)
        self.assertEqual(check.status, 'pass')


class EvidenceTests(unittest.TestCase):
    head = 'c' * 40

    def body(self, result='pass', head=None):
        summary = {'schema': 1, 'head': head or self.head, 'dirty': False, 'base_ref': 'origin/main',
                   'merge_base': 'b' * 40, 'changed_file_count': 1, 'duration_seconds': 1.0, 'result': result,
                   'checks': []}
        return 'Intro\n\n' + record.markdown(summary)

    def test_generated_passing_record_at_head_is_accepted(self):
        self.assertEqual(evidence.evaluate(self.body(), self.head, 'crmitchelmore')[0], 'ok')

    def test_missing_and_failing_records_are_errors(self):
        self.assertEqual(evidence.evaluate('No evidence', self.head, 'crmitchelmore')[0], 'error')
        self.assertEqual(evidence.evaluate(self.body('fail'), self.head, 'crmitchelmore')[0], 'error')

    def test_stale_record_is_a_warning(self):
        self.assertEqual(evidence.evaluate(self.body(head='d' * 40), self.head, 'crmitchelmore')[0], 'warning')

    def test_strict_mode_rejects_a_record_for_another_commit(self):
        stale = self.body(head='d' * 40)
        self.assertEqual(evidence.evaluate(stale, self.head, 'crmitchelmore', strict=True)[0], 'error')
        self.assertEqual(evidence.evaluate(self.body(), self.head, 'crmitchelmore', strict=True)[0], 'ok')

    def test_strict_mode_accepts_a_record_for_the_same_tree(self):
        tree = 'e' * 40
        body = stale = self.body(head='d' * 40).replace('"result"', f'"tree": "{tree}", "result"')
        self.assertEqual(evidence.evaluate(body, self.head, 'crmitchelmore', tree, strict=True)[0], 'ok')
        self.assertEqual(evidence.evaluate(stale, self.head, 'crmitchelmore', 'f' * 40, strict=True)[0], 'error')

    def test_only_dependabot_is_exempt(self):
        self.assertEqual(evidence.evaluate('', self.head, 'dependabot[bot]')[0], 'ok')
        for agent in ('devin-ai-integration[bot]', 'Copilot[bot]', 'renovate[bot]'):
            self.assertEqual(evidence.evaluate('', self.head, agent)[0], 'error', agent)



@unittest.skipIf(sys.platform == 'win32', 'flock is POSIX-only')
class MachineLockTests(unittest.TestCase):
    def test_a_second_run_waits_until_the_first_releases_the_lock(self):
        import threading
        with tempfile.TemporaryDirectory() as tmp:
            path = str(Path(tmp) / 'nested' / 'pre-pr.lock')
            order, entered = [], threading.Event()

            def second():
                with lock.machine_lock(path, slots=1, poll=0.05):
                    order.append('second')
                entered.set()

            with lock.machine_lock(path, slots=1):
                waiter = threading.Thread(target=second)
                waiter.start()
                self.assertFalse(entered.wait(0.5), 'the second run must wait for the lock')
                order.append('first')
            self.assertTrue(entered.wait(10))
            waiter.join(10)
            self.assertEqual(order, ['first', 'second'])

    def test_two_slots_admit_two_runs_and_the_third_waits(self):
        import threading
        with tempfile.TemporaryDirectory() as tmp:
            path = str(Path(tmp) / 'pre-pr.lock')
            entered = threading.Event()
            got = []

            def third():
                with lock.machine_lock(path, slots=2, poll=0.05) as slot:
                    got.append(slot)
                entered.set()

            with lock.machine_lock(path, slots=2) as first:
                with lock.machine_lock(path, slots=2) as second:
                    self.assertEqual((first, second), (0, 1))
                    waiter = threading.Thread(target=third)
                    waiter.start()
                    self.assertFalse(entered.wait(0.3), 'a third run must wait for a free slot')
                self.assertTrue(entered.wait(10))
            waiter.join(10)
            self.assertEqual(got, [1])

    def test_off_disables_the_lock(self):
        with lock.machine_lock('off'), lock.machine_lock('off'):
            pass


class LockScopeTests(unittest.TestCase):
    def test_only_local_heavy_checks_take_the_machine_lock(self):
        swift = 'Sources/SpeakCore/Credentials/Apple/SecureStorage.swift'
        with mock.patch.object(environment, 'IS_MAC', True), mock.patch.object(sys, 'platform', 'darwin'), \
                mock.patch.object(environment, 'pr_title_env', lambda: {}):
            remote = {c.id: c for c in planner.plan([swift, 'scripts/pre-pr'], False, linux='remote')[0]}
            container = {c.id: c for c in planner.plan([swift], False, linux='container')[0]}
            with mock.patch.object(planner.shutil, 'which', lambda name: name == 'container' and '/bin/container'):
                apple = {c.id: c for c in planner.plan([swift], False)[0]}
        self.assertTrue(apple['portable-linux'].exclusive)
        self.assertFalse(any(remote[i].exclusive for i in ('portable-linux', 'ci-lint-linux', 'quality')))
        self.assertTrue(all(remote[i].exclusive for i in ('ci-lint', 'apple-build', 'api-compatibility')))
        self.assertTrue(container['portable-linux'].exclusive)

    def run_execute(self, checks, failing=(), slot=0):
        events, held = [], []

        @contextlib.contextmanager
        def fake_lock():
            held.append(True)
            events.append('lock')
            yield slot
            events.append('unlock')
            held.pop()

        def fake_run(check, verbose, cancel=None):
            events.append((check.id, bool(held)))
            check.status = 'fail' if check.id in failing else 'pass'

        def fake_finish(check, process, verbose, restore=True):
            if process is not None:
                check.status = 'pass'

        args = mock.Mock(keep_going=False, verbose=False, markdown=False, base='origin/main', full=False)
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(environment, 'OUT', Path(tmp)), \
                mock.patch.object(cli, 'machine_lock', fake_lock), mock.patch.object(cli, 'run', fake_run), \
                mock.patch.object(cli, 'launch', lambda c: events.append((c.id, bool(held))) or object()), \
                mock.patch.object(cli, 'finish', fake_finish), mock.patch('builtins.print'):
            cli.execute(args, checks, {}, [], 'base', 'head', 'tree', False)
        return events

    def test_a_second_slot_uses_its_own_linux_volume(self):
        Check = runner.Check
        checks = [Check('portable-linux', 'swift', 'Linux', ['x'], background=True),
                  Check('ci-lint', 'ci-lint', 'Lint', ['x'])]
        with mock.patch.object(mirror, 'sync', return_value=None):
            self.run_execute(checks, slot=1)
        self.assertEqual(checks[0].env['JSTI_PORTABLE_VOLUME'], 'jsti-portable-build-1')

    def test_the_lock_covers_only_the_exclusive_checks(self):
        Check = runner.Check
        checks = [Check('linux', 'swift', 'Linux', ['x'], background=True, exclusive=False),
                  Check('quality', 'quality', 'Quality', ['x'], exclusive=False),
                  Check('ci-lint', 'ci-lint', 'Lint', ['x']), Check('apple-build', 'swift', 'Build', ['x'])]
        events = self.run_execute(checks)
        # ci-lint and the build are separate lanes, so their order is not fixed.
        self.assertEqual(events[:3], [('linux', False), ('quality', False), 'lock'])
        self.assertCountEqual(events[3:5], [('ci-lint', True), ('apple-build', True)])
        self.assertEqual(events[5:], ['unlock'])
        self.assertEqual([c.status for c in checks], ['pass'] * 4)

    def test_an_early_failure_never_waits_for_the_lock(self):
        Check = runner.Check
        checks = [Check('quality', 'quality', 'Quality', ['x'], exclusive=False),
                  Check('apple-build', 'swift', 'Build', ['x'])]
        self.assertEqual(self.run_execute(checks, failing={'quality'}), [('quality', False)])
        self.assertEqual(checks[1].status, 'skip')


class LaneTests(unittest.TestCase):
    """The exclusive checks run in lanes side by side, for real, without the machine lock."""

    def execute(self, checks, **env):
        args = mock.Mock(keep_going=False, verbose=False, markdown=False, base='origin/main', full=False)
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(environment, 'OUT', Path(tmp)), \
                mock.patch.object(cli, 'machine_lock', contextlib.nullcontext), \
                mock.patch.object(runner, 'dirty_tracked', lambda *_: set()), \
                mock.patch.dict(os.environ, env), mock.patch('builtins.print'):
            started = time.monotonic()
            cli.execute(args, checks, {}, [], 'base', 'head', 'tree', False)
            return time.monotonic() - started

    def test_lanes_run_side_by_side_and_in_order_within_a_lane(self):
        Check = runner.Check
        with tempfile.TemporaryDirectory() as tmp:
            order = Path(tmp) / 'order'
            step = ['sh', '-c', f'sleep 1; echo "$0" >> {order}']
            checks = [Check('build', 'swift', 'Build', [*step, 'build'], lane='swift'),
                      Check('tests', 'swift', 'Tests', [*step, 'tests'], lane='swift'),
                      Check('api', 'public-api', 'API', [*step, 'api']),
                      Check('lint', 'ci-lint', 'Lint', [*step, 'lint'])]
            elapsed = self.execute(checks)
            lines = order.read_text().split()
        self.assertEqual([c.status for c in checks], ['pass'] * 4)
        self.assertLess(lines.index('build'), lines.index('tests'))
        self.assertLess(elapsed, 3.8, 'three lanes of at most two 1s steps run side by side')

    def test_lanes_off_runs_one_check_at_a_time(self):
        Check = runner.Check
        checks = [Check(name, 'x', name, ['sleep', '0.5']) for name in ('a', 'b', 'c')]
        self.assertGreaterEqual(self.execute(checks, JSTI_PRE_PR_LANES='off'), 1.5)

    def test_a_failure_stops_the_other_lanes(self):
        Check = runner.Check
        checks = [Check('build', 'swift', 'Build', ['sh', '-c', 'sleep 0.5; exit 1'], lane='swift'),
                  Check('tests', 'swift', 'Tests', ['true'], lane='swift'),
                  Check('lint', 'ci-lint', 'Lint', ['sleep', '60'])]
        self.assertLess(self.execute(checks), 20)
        self.assertEqual([c.status for c in checks], ['fail', 'skip', 'skip'])
        self.assertIn('earlier failure', checks[2].note)


class MirrorTests(unittest.TestCase):
    """The warm build mirror, against a throwaway repository."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        base = Path(self.tmp.name).resolve()
        self.repo, self.mirror = base / 'repo', base / 'cache' / 'mirror'
        self.repo.mkdir()
        self.git('init', '-q')
        (self.repo / '.gitignore').write_text('.build/\n')
        (self.repo / 'kept.swift').write_text('let kept = 1\n')
        (self.repo / 'edited.swift').write_text('let edited = 1\n')
        self.git('add', '-A')
        self.git('-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-qm', 'base')
        patches = [mock.patch.object(environment, 'ROOT', self.repo), mock.patch.object(mirror, 'ROOT', self.repo),
                   mock.patch.object(runner, 'ROOT', self.repo),
                   mock.patch.dict(os.environ, {'JSTI_PRE_PR_MIRROR': str(self.mirror)})]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)

    def tearDown(self):
        self.tmp.cleanup()

    def git(self, *args):
        return subprocess.run(['git', *args], cwd=self.repo, check=True, capture_output=True, text=True).stdout.strip()

    def sync(self):
        path = mirror.sync(environment.worktree_tree(), self.git('rev-parse', 'HEAD'))
        self.assertEqual(path, self.mirror)
        return path

    def test_mirror_holds_the_working_tree_and_keeps_unchanged_files_untouched(self):
        (self.repo / 'edited.swift').write_text('let edited = 2\n')
        (self.repo / 'new.swift').write_text('let new = 1\n')
        (self.repo / 'ignored.local').write_text('secret\n')  # not ignored: untracked files count
        (self.repo / '.build').mkdir()
        (self.repo / '.build' / 'junk').write_text('x')
        path = self.sync()
        self.assertEqual((path / 'edited.swift').read_text(), 'let edited = 2\n')
        self.assertTrue((path / 'new.swift').exists())
        self.assertFalse((path / '.build' / 'junk').exists(), 'ignored files stay out, as in CI')
        (path / '.build').mkdir()
        (path / '.build' / 'warm').write_text('cache')
        (path / 'leftover.txt').write_text('a check made this')
        kept = (path / 'kept.swift').stat().st_mtime_ns
        time.sleep(0.05)
        (self.repo / 'edited.swift').write_text('let edited = 3\n')
        (self.repo / 'new.swift').unlink()
        self.sync()
        self.assertEqual((path / 'kept.swift').stat().st_mtime_ns, kept, 'an unchanged file is not rewritten')
        self.assertEqual((path / 'edited.swift').read_text(), 'let edited = 3\n')
        self.assertFalse((path / 'new.swift').exists())
        self.assertFalse((path / 'leftover.txt').exists())
        self.assertEqual((path / '.build' / 'warm').read_text(), 'cache', 'the warm build survives')

    def test_a_broken_mirror_is_recreated_with_its_build_kept(self):
        path = self.sync()
        (path / '.build').mkdir()
        (path / '.build' / 'warm').write_text('cache')
        (path / '.git').unlink()
        self.sync()
        self.assertEqual((path / '.build' / 'warm').read_text(), 'cache')
        self.assertTrue((path / 'kept.swift').exists())

    def test_each_lock_slot_has_its_own_mirror(self):
        first = self.sync()
        second = mirror.sync(environment.worktree_tree(), self.git('rev-parse', 'HEAD'), slot=1)
        self.assertEqual(second, Path(f'{self.mirror}-1'))
        self.assertNotEqual(first, second)
        self.assertTrue((second / 'kept.swift').exists())

    def test_off_builds_in_place(self):
        with mock.patch.dict(os.environ, {'JSTI_PRE_PR_MIRROR': 'off'}):
            self.assertIsNone(mirror.sync(environment.worktree_tree(), self.git('rev-parse', 'HEAD')))

    def test_a_mirrored_check_runs_there_but_reports_worktree_paths(self):
        path = self.sync()
        scratch = self.repo / '.build' / 'pre-pr' / 'apple-build'
        check = runner.Check('apple-build', 'swift', 'Build', ['sh', '-c', 'echo "$PWD/x.swift:1: error $0"',
                                                                 str(scratch)], cwd=self.repo, mirror=True)
        runner.relocate(check, path)
        self.assertEqual(check.command[-1], str(path / '.build' / 'pre-pr' / 'apple-build'))
        with mock.patch.object(environment, 'OUT', Path(self.tmp.name) / 'out'):
            runner.run(check, verbose=False)
            log = check.log.read_text()
        self.assertEqual(check.status, 'pass')
        self.assertIn(f'{self.repo}/x.swift:1: error {scratch}', log)
        self.assertNotIn(str(path), log)


if __name__ == '__main__':
    unittest.main()
