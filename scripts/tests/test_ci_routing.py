"""Characterises which checks a changed path routes to, in scripts/pre-pr and in the workflows.

Each row names one changed path and records the areas pre-pr selects for it,
the outputs ci.yml's `Detect Release-Relevant Changes` filters produce, and
whether android.yml's push path filter starts the Android workflow on main
(it has no pull-request trigger; pre-pr runs it before the merge). The workflow
side is evaluated from the workflow YAML with GitHub's glob rules, so a drift
between the workflows and pre-pr changes a row and fails.

Regenerate the table only for an intended routing change, and review the diff:
    python3 scripts/tests/test_ci_routing.py --regenerate
"""
import importlib.machinery
import importlib.util
import json
import re
import sys
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
TABLE_PATH = Path(__file__).resolve().parent / 'fixtures' / 'ci-routing-truth-table.json'
_loader = importlib.machinery.SourceFileLoader('pre_pr', str(ROOT / 'scripts' / 'pre-pr'))
_spec = importlib.util.spec_from_loader('pre_pr', _loader)
pre_pr = importlib.util.module_from_spec(_spec)
sys.modules['pre_pr'] = pre_pr
_loader.exec_module(pre_pr)

PATHS = [
    # Docs, website, Android and Workers: no Apple lint.
    'README.md', 'Docs/Architecture.md', 'Docs/manual-checks.yml', 'Sources/SpeakApp/README.md',
    'landing-page/index.html', 'landing-page/qa/index.html', '.github/workflows/deploy-landing-page.yml',
    'workers/paid-access/src/index.ts', 'workers/other/x.ts',
    'android/app/build.gradle.kts', '.github/workflows/android.yml',
    # Android parity inputs.
    'Sources/SpeakCore/TranscriptCleanupPolicy.swift', 'Sources/SpeakCore/ModelCatalog.swift',
    'Sources/SpeakCore/ModelRetirements.swift', 'Sources/SpeakCore/ProviderCredentialCatalogue.swift',
    'Sources/SpeakCore/OpenAITranscriptionModels.swift',
    # Swift package inputs and API products.
    'Package.swift', 'Package.resolved', 'Makefile', 'Config/AppInfo.plist', 'Resources/Sounds/start.caf',
    'Sources/SpeakApp/AppDelegate.swift', 'Sources/SpeakCore/Recording/Thing.swift',
    'Sources/SpeakSync/Sync.swift', 'Sources/SpeakiOS/Views/Home.swift', 'Sources/SpeakHotKeys/HotKey.swift',
    'Sources/SpeakAutomationKit/Kit.swift', 'Sources/SpeakWatchCore/Watch.swift',
    'Sources/SpeakDesktop/Desktop.swift', 'Sources/SpeakLinux/main.swift',
    'Tests/SpeakAppTests/HistoryTests.swift', 'Tests/SpeakCoreTests/X.swift', 'Tests/SpeakAppUITests/X.swift',
    # Windows.
    'Sources/SpeakWindows/App.swift', 'Sources/SpeakWindowsPlatform/P.swift', 'Sources/CWindowsSupport/x.cpp',
    'Tests/SpeakWindowsPlatformTests/T.swift', 'scripts/typecheck-windows-swift.sh',
    # Scripts the Swift jobs run, the API gate and other tooling.
    'scripts/affected-swift-tests.py', 'scripts/retry-network.sh', 'scripts/retry-xctest-crash.py',
    'scripts/with-test-keychain.py', 'scripts/private-test-keychain.py', 'scripts/verify-portable-core-boundary.py',
    'scripts/collect-macos-sample-contract.py', 'scripts/collect-macos-xctest-crashes.py',
    'scripts/prepare-mac-cli-symbols.sh', 'scripts/tests/brand-assets.test.mjs',
    'scripts/check-api-compatibility.sh', 'scripts/api-breakage-allowlist.txt', 'scripts/ci-api-compatibility.sh',
    'scripts/release-train.mjs', 'scripts/pre-pr', 'scripts/install-pre-pr-hook', 'scripts/linux-precheck',
    'scripts/create-dmg.sh', 'scripts/windows-bundle/build-windows-bundle.py', 'scripts/tests/test_pre_pr.py',
    '.githooks/pre-push', 'Tooling/Package.resolved', '.swiftlint-baseline.json', '.swiftlint.yml',
    # Workflows and other repository inputs.
    '.github/workflows/ci.yml', '.github/workflows/windows.yml', '.github/actions/setup/action.yml',
    '.github/actionlint.yaml', '.github/scripts/dependabot-merge.mjs', 'Project.swift', 'packaging/linux/x.desktop',
    'SpeakiOSApp/Info.plist', 'JustSpeakKeyboard/KeyboardViewController.swift',
]


def glob_regex(pattern: str) -> re.Pattern:
    """GitHub's path-filter glob (as dorny/paths-filter and `on.<event>.paths` match it): `**` spans
    directories, `*` and `?` stay inside one, and dot files match."""
    out, i = '', 0
    while i < len(pattern):
        if pattern.startswith('**/', i):
            out, i = out + '(?:.*/)?', i + 3
        elif pattern.startswith('**', i):
            out, i = out + '.*', i + 2
        elif pattern[i] == '*':
            out, i = out + '[^/]*', i + 1
        elif pattern[i] == '?':
            out, i = out + '[^/]', i + 1
        else:
            out, i = out + re.escape(pattern[i]), i + 1
    return re.compile(out + r'\Z')


def glob_any(path: str, patterns: list[str]) -> bool:
    """`on.<event>.paths` and the default some-pattern quantifier: a later `!pattern` excludes."""
    selected = False
    for pattern in patterns:
        if pattern.startswith('!'):
            selected = selected and not glob_regex(pattern[1:]).match(path)
        elif glob_regex(pattern).match(path):
            selected = True
    return selected


def glob_every(path: str, patterns: list[str]) -> bool:
    """dorny/paths-filter's `predicate-quantifier: every`."""
    return all(not glob_regex(p[1:]).match(path) if p.startswith('!') else bool(glob_regex(p).match(path))
               for p in patterns)


def yaml_list(text: str, header: str) -> list[str]:
    """The `- item` lines that follow the first line equal to header (comments skipped)."""
    lines = text.split('\n')
    start = lines.index(header) + 1
    items = []
    for line in lines[start:]:
        stripped = line.strip()
        if stripped.startswith('#') or not stripped:
            if items and not stripped:
                break
            continue
        if not stripped.startswith('- '):
            break
        items.append(stripped[2:].strip("'\""))
    return items


def workflow_routes(path: str) -> dict:
    ci = (ROOT / '.github' / 'workflows' / 'ci.yml').read_text(encoding='utf-8')
    android = (ROOT / '.github' / 'workflows' / 'android.yml').read_text(encoding='utf-8')
    push = android.split('\n  push:\n', 1)[1]
    routes = {name: glob_any(path, yaml_list(ci, f'            {name}:')) for name in ('swift', 'api', 'ios')}
    routes['apple'] = glob_every(path, yaml_list(ci, '            apple:'))
    routes['android'] = glob_any(path, yaml_list(push, '    paths:'))
    return routes


def pre_pr_areas(path: str) -> list[str]:
    with mock.patch.object(pre_pr, 'load_graph', lambda portable: None), \
            mock.patch.object(pre_pr, 'pr_title_env', lambda: {}), \
            mock.patch.object(pre_pr, 'merge_base_or', lambda base: base), \
            mock.patch.object(pre_pr, 'android_runs_locally', lambda: False):
        _, areas = pre_pr.plan([path], False)
    return sorted(areas)


def observe(path: str) -> dict:
    return {'path': path, 'pre_pr': pre_pr_areas(path), 'workflows': workflow_routes(path)}


class RoutingTruthTableTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.table = json.loads(TABLE_PATH.read_text(encoding='utf-8'))

    def test_every_path_routes_exactly_as_recorded(self):
        self.assertEqual([row['path'] for row in self.table], PATHS)
        for row in self.table:
            with self.subTest(path=row['path']):
                self.assertEqual(observe(row['path']), row)

    def test_pre_pr_runs_what_the_ci_gate_would(self):
        """Lint, the Swift jobs and Android agree between pre-pr and the workflows, path by path. pre-pr
        deliberately also runs the API gate when its own CI script changes."""
        for row in self.table:
            areas, ci = set(row['pre_pr']), row['workflows']
            with self.subTest(path=row['path']):
                self.assertEqual('ci-lint' in areas, ci['apple'])
                self.assertEqual('swift' in areas, ci['swift'])
                self.assertEqual('android' in areas, ci['android'])
                expected_api = ci['api'] or row['path'] == 'scripts/ci-api-compatibility.sh'
                self.assertEqual('public-api' in areas, expected_api)

    def test_glob_semantics(self):
        self.assertTrue(glob_any('Sources/A/B.swift', ['Sources/**']))
        self.assertFalse(glob_any('scripts/collect-macos-a/b.py', ['scripts/collect-macos-*.py']))
        self.assertTrue(glob_any('README.md', ['**/*.md']))
        self.assertTrue(glob_any('.github/x', ['**']))
        self.assertFalse(glob_every('Docs/a.txt', ['**', '!Docs/**']))


if __name__ == '__main__':
    if sys.argv[1:] == ['--regenerate']:
        TABLE_PATH.write_text(json.dumps([observe(p) for p in PATHS], indent=1) + '\n', encoding='utf-8')
    else:
        unittest.main()
