"""Planner and summary tests for scripts/pre-pr."""
import importlib.machinery
import importlib.util
import json
import re
import sys
import tempfile
import unittest
from unittest import mock
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

    def test_tooling_change_runs_the_ci_lint_job(self):
        selected, _, checks = ids(['scripts/release-train.mjs'])
        selected = [c for c in selected if c != 'ci-lint-linux']
        checks = [c for c in checks if c.id == 'ci-lint']
        self.assertEqual(selected, ['ci-lint'])
        self.assertEqual(checks[0].command, ['make', 'ci-lint'])
        self.assertEqual(checks[0].forbid_drift, ('Tooling/Package.resolved',))
        self.assertEqual(checks[0].env, {'JSTI_LINT_BASELINE_BASE': 'origin/main'})

    def test_workflow_change_adds_actionlint(self):
        selected, _, _ = ids(['.github/workflows/ci.yml'])
        self.assertIn('actionlint', selected)
        self.assertIn('ci-lint', selected)
        self.assertNotIn('portable-linux', selected)

    def test_android_runs_remotely_without_a_working_jdk_and_feed(self):
        with mock.patch.dict(pre_pr.os.environ, {'JSTI_ANDROID_LOCAL': '0'}):
            checks, _ = pre_pr.plan(['android/app/build.gradle.kts'], False)
        android = {c.id: c for c in checks}['android']
        self.assertTrue(android.background)
        self.assertEqual(android.command[:4], ['python3', 'scripts/linux-precheck', '--job', 'android'])
        self.assertFalse(android.advisory or android.skip_reason or android.requires)
        with mock.patch.dict(pre_pr.os.environ, {'JSTI_ANDROID_LOCAL': '1'}):
            checks, _ = pre_pr.plan(['android/app/build.gradle.kts'], False)
        self.assertEqual({c.id: c for c in checks}['android'].command, ['bash', 'scripts/ci-android.sh'])

    def test_macos_java_stub_is_not_a_jdk(self):
        failing = mock.Mock(returncode=1)
        with mock.patch.dict(pre_pr.os.environ, {'JSTI_MAVEN_MIRROR': 'https://feed'}), \
                mock.patch.object(pre_pr.subprocess, 'run', return_value=failing):
            pre_pr.os.environ.pop('JSTI_ANDROID_LOCAL', None)
            self.assertFalse(pre_pr.android_runs_locally())

    def test_public_library_change_runs_the_api_compatibility_job(self):
        with mock.patch.object(pre_pr, 'IS_MAC', True), mock.patch.object(pre_pr, 'pr_title_env', lambda: {}):
            checks, areas = pre_pr.plan(['Sources/SpeakCore/OpenRouter/Apple/OpenRouterAPIClient.swift'], False)
            api = {c.id: c for c in checks}['api-compatibility']
            self.assertEqual(api.command[:2], ['bash', 'scripts/ci-api-compatibility.sh'])
            self.assertEqual(api.command[2], pre_pr.merge_base_or('origin/main'))
            self.assertIn('public-api', areas)
            for path in ('Sources/SpeakApp/AppDelegate.swift', 'Sources/SpeakDesktop/X.swift', 'Docs/x.md'):
                ids_ = [c.id for c in pre_pr.plan([path], False)[0]]
                self.assertNotIn('api-compatibility', ids_, path)
        with mock.patch.object(pre_pr, 'IS_MAC', False):
            api = {c.id: c for c in pre_pr.plan(['Package.swift'], False)[0]}['api-compatibility']
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
        if pre_pr.IS_MAC:
            self.assertIn('apple-build', selected)
            self.assertEqual({c.id: c for c in checks}['apple-build'].forbid_drift, ('Package.resolved',))

    def test_lint_also_runs_on_ubuntu_like_ci(self):
        with mock.patch.object(pre_pr.sys, 'platform', 'darwin'):
            checks = {c.id: c for c in pre_pr.plan(['scripts/release-train.mjs'], False)[0]}
            self.assertEqual(checks['ci-lint-linux'].command[2:4], ['--job', 'lint'])
            self.assertTrue(checks['ci-lint-linux'].background)
            skipped = {c.id: c for c in pre_pr.plan(['scripts/release-train.mjs'], False, linux='skip')[0]}
            self.assertTrue(skipped['ci-lint-linux'].incomplete)
        with mock.patch.object(pre_pr.sys, 'platform', 'linux'):
            ids_ = [c.id for c in pre_pr.plan(['scripts/release-train.mjs'], False)[0]]
        self.assertNotIn('ci-lint-linux', ids_)

    def test_linux_modes(self):
        for mode, flag in (('remote', '--remote'), ('container', '--container')):
            checks, _ = pre_pr.plan(['Package.swift'], False, linux=mode)
            self.assertIn(flag, checks[0].command)
        checks, _ = pre_pr.plan(['Package.swift'], False, linux='skip')
        linux = {c.id: c for c in checks}['portable-linux']
        self.assertTrue(linux.incomplete)
        self.assertEqual(linux.skip_reason, '--no-linux')

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
        text = pre_pr.markdown(summary)
        marker = text.split('<!-- pre-pr-summary ')[1].split(' -->')[0]
        self.assertEqual(json.loads(marker), {'schema': 1, 'head': 'a' * 40, 'result': 'pass'})
        summary['tree'] = 'c' * 40
        marker = pre_pr.markdown(summary).split('<!-- pre-pr-summary ')[1].split(' -->')[0]
        self.assertEqual(json.loads(marker)['tree'], 'c' * 40)

    def test_worktree_tree_matches_a_clean_head(self):
        if pre_pr.git('status', '--porcelain'):
            self.skipTest('only comparable on a clean checkout')
        self.assertEqual(pre_pr.worktree_tree(), pre_pr.git('rev-parse', 'HEAD^{tree}'))


class CIParityTests(unittest.TestCase):
    """pre-pr must run CI's commands. Path routing is shared through scripts/ci/routing.json (test_ci_routing)."""

    ci = (ROOT / '.github' / 'workflows' / 'ci.yml').read_text(encoding='utf-8')
    # ci.yml's macOS Debug lane, which runs the affected unit tests.
    macos = (ROOT / '.github' / 'workflows' / 'ci-macos-debug.yml').read_text(encoding='utf-8')

    def test_macos_skip_targets_match_ci(self):
        self.assertEqual(set(re.findall(r'--skip-target (\w+)', self.macos)), pre_pr.CI_MACOS_SKIP_TARGETS)

    def test_android_command_matches_android_yml(self):
        android = (ROOT / '.github' / 'workflows' / 'android.yml').read_text(encoding='utf-8')
        self.assertIn('run: ../scripts/ci-android.sh', android)
        precheck = (ROOT / '.github' / 'workflows' / 'precheck.yml').read_text(encoding='utf-8')
        self.assertIn('run: scripts/ci-android.sh', precheck)
        for action in re.findall(r'uses: (actions/setup-java@\S+|gradle/actions/setup-gradle@\S+)', android):
            self.assertIn(action, precheck)

    def test_plan_needs_no_history(self):
        # CI's Lint job runs these tests in a shallow checkout without origin/main.
        with mock.patch.object(pre_pr, 'IS_MAC', True), mock.patch.object(pre_pr, 'pr_title_env', lambda: {}):
            checks, _ = pre_pr.plan(['Package.swift'], False, base='no-such-ref/main')
        self.assertEqual({c.id: c for c in checks}['api-compatibility'].command[2], 'no-such-ref/main')

    def test_api_products_match_the_gate(self):
        gate = (ROOT / 'scripts' / 'check-api-compatibility.sh').read_text(encoding='utf-8')
        products = set(re.search(r'PRODUCTS=\(([^)]*)\)', gate).group(1).split()) | {'SpeakWatchCore'}
        dirs = {'SpeakiOSLib': 'SpeakiOS'}
        for product in products:
            self.assertIn(f'Sources/{dirs.get(product, product)}/**', pre_pr.routing().routes()['api']['paths'],
                          product)

    def test_linux_image_is_the_ci_image(self):
        image = re.search(r'image: (swift:[^\s]+)', self.ci.split('Portable Swift (Linux)', 1)[1]).group(1)
        precheck = (ROOT / '.github' / 'workflows' / 'precheck.yml').read_text(encoding='utf-8')
        self.assertIn(f'image: {image}', precheck)
        self.assertIn(image, (ROOT / 'scripts' / 'linux-precheck').read_text(encoding='utf-8'))
        self.assertIn('scripts/ci-portable-linux.sh', precheck)


def fake_graph():
    return pre_pr.Graph.from_dump({'targets': [
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
        return pre_pr.select_tests(files, full, self.graph, set(exclude), root=self.root)

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
        self.assertEqual(pre_pr.uncovered_modules(['Sources/Demo/main.swift'], [self.graph]), ['Demo'])
        self.assertEqual(pre_pr.uncovered_modules(['Sources/Core/Helpers.swift'], [self.graph]), [])

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
        self.assertEqual(pre_pr.uncovered_modules(['Sources/Windows/App.swift'], [self.graph]), [])

    def test_uncovered_module_adds_a_failing_check(self):
        with mock.patch.object(pre_pr, 'IS_MAC', True), \
                mock.patch.object(pre_pr, 'load_graph', lambda portable: None if portable else self.graph), \
                mock.patch.object(pre_pr, 'ROOT', self.root):
            checks, _ = pre_pr.plan(['Sources/Demo/main.swift'], False)
        by_id = {c.id: c for c in checks}
        self.assertIn('Demo', by_id['swift-test-coverage'].failure)
        order = [c.id for c in checks]
        self.assertLess(order.index('swift-test-coverage'), order.index('apple-build'), 'cheap failures run first')

    def test_unreadable_graph_fails_closed(self):
        with mock.patch.object(pre_pr, 'IS_MAC', True), mock.patch.object(pre_pr, 'load_graph', lambda _: None):
            checks, _ = pre_pr.plan(['Sources/SpeakCore/Credentials/Apple/SecureStorage.swift'], False)
        self.assertTrue({c.id: c for c in checks}['apple-unit-tests'].failure)


class RunTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.out = mock.patch.object(pre_pr, 'OUT', Path(self.tmp.name))
        self.out.start()

    def tearDown(self):
        self.out.stop()
        self.tmp.cleanup()

    def run_check(self, **kwargs):
        check = pre_pr.Check('x', 'tooling', 'x', kwargs.pop('command', ['true']), **kwargs)
        with mock.patch.object(pre_pr, 'restore_side_effects', lambda *_: None):
            pre_pr.run(check, verbose=False)
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
        with mock.patch.object(pre_pr, 'dirty_tracked', lambda: next(states)):
            check = self.run_check(forbid_drift=('Package.resolved',))
        self.assertEqual(check.status, 'fail')
        self.assertIn('Package.resolved', check.note)

    def test_counts_both_test_frameworks(self):
        log = 'Executed 4 tests\nExecuted 12 tests, with 0 failures\n✔ Test run with 7 tests in 2 suites passed'
        self.assertEqual(pre_pr.tests_executed(log), 19)
        self.assertEqual(pre_pr.tests_executed('No matching test cases were run'), 0)


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
                with pre_pr.machine_lock(path):
                    order.append('second')
                entered.set()

            with pre_pr.machine_lock(path):
                waiter = threading.Thread(target=second)
                waiter.start()
                self.assertFalse(entered.wait(0.5), 'the second run must wait for the lock')
                order.append('first')
            self.assertTrue(entered.wait(10))
            waiter.join(10)
            self.assertEqual(order, ['first', 'second'])

    def test_off_disables_the_lock(self):
        with pre_pr.machine_lock('off'), pre_pr.machine_lock('off'):
            pass


if __name__ == '__main__':
    unittest.main()
