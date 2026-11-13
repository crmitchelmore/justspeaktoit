"""Which checks the CI Gate's pull-request jobs would run for a set of changed
files: the routes in scripts/ci/routing.json decide the areas, and each area
adds the CI job's own command."""
from __future__ import annotations

import shutil
import sys
from pathlib import Path

from pre_pr import environment, swift_tests
from pre_pr.environment import quality, routing
from pre_pr.runner import Check
from pre_pr.swift_tests import (
    CI_MACOS_SKIP_TARGETS,
    UI_TEST_TARGETS,
    Selection,
    ci_macos_tests,
    select_tests,
    test_title,
    uncovered_modules,
)

# Cheap static checks run first so most failures surface within seconds.
COST = {'swift-test-coverage': 0, 'autofix': 0, 'quality': 1, 'landing-tests': 1,
        'ci-lint': 2, 'apple-build': 3, 'apple-unit-tests': 4, 'api-compatibility': 5}


def plan(files: list[str], full: bool, quick: bool = False, linux: str = 'auto', base: str = 'origin/main'
         ) -> tuple[list[Check], dict[str, list[str]]]:
    """Mirror the CI Gate's pull-request jobs (Lint, Portable Swift (Linux), the macOS job) for these files.

    full: whole affected test targets. quick: type-level test selection instead of CI's target-level one.
    linux: auto (container if available, else remote), container, remote, or skip (result 'incomplete').
    """
    areas: dict[str, list[str]] = {}

    def area(name: str, route: str) -> list[str]:
        hits = [f for f in files if routing().matches(route, f, pre_pr=True)]
        if hits:
            areas[name] = hits
        return hits

    # scripts/ci/routing.json owns these routes; ci.yml's and android.yml's path filters are generated from it.
    apple = area('ci-lint', 'apple')
    swift = area('swift', 'swift')
    api = area('public-api', 'api')
    windows = area('windows', 'windows')
    area('workflows', 'workflows')
    area('shell', 'shell')
    android = area('android', 'android')
    worker = area('paid-access-worker', 'paid-access-worker')
    landing = area('landing-page', 'landing-page')

    checks: list[Check] = []
    swift_changes = [f for f in files if f.endswith('.swift') and f.startswith(('Sources/', 'Tests/'))]
    test_env = {'JSTI_TEST_KEYCHAIN_REDIRECT': '1', 'JSTI_TEST_KEYCHAIN': '1'}
    scratch = ['--scratch-path', str(environment.OUT / 'apple-build')]

    if swift:
        # Portable Swift (Linux): the CI job's own script in the CI image, started first because it is slowest.
        title = 'Portable Swift (Linux): scripts/ci-portable-linux.sh in swift:6.2.3-jammy'
        if linux == 'skip':
            checks.append(Check('portable-linux', 'swift', title, [], skip_reason='--no-linux', incomplete=True))
        else:
            mode = [] if linux == 'auto' else [f'--{linux}']
            # auto uses a container when docker, podman or Apple container runs; an installed one counts,
            # to stay on the safe side.
            local = linux == 'container' or (linux == 'auto'
                                             and any(map(shutil.which, ('docker', 'podman', 'container'))))
            checks.append(Check('portable-linux', 'swift', title,
                                ['python3', 'scripts/linux-precheck', *mode, '--tree', str(environment.ROOT),
                                 '--base', base], background=True, exclusive=local))
    if apple:
        # Lint: exactly the ci.yml Lint job (whole-repo strict SwiftLint, accessibility, tooling pins and tests).
        # JSTI_TEST_RETRY: other agents load this machine, so a Python tooling test that fails here is rerun
        # once serially; the remote Ubuntu run (ci-lint-linux) and CI stay strict.
        checks.append(Check('ci-lint', 'ci-lint', 'CI Lint job (make ci-lint)', ['make', 'ci-lint'],
                            env={'JSTI_LINT_BASELINE_BASE': base, 'JSTI_TEST_RETRY': '1'},
                            forbid_drift=('Tooling/Package.resolved',)))
        if not sys.platform.startswith('linux') and linux != 'skip':
            # CI runs Lint on Ubuntu, where Apple-only tooling tests skip and others behave differently.
            checks.append(Check('ci-lint-linux', 'ci-lint', 'CI Lint job on Ubuntu (make ci-lint), remote',
                                ['python3', 'scripts/linux-precheck', '--job', 'lint',
                                 '--tree', str(environment.ROOT), '--base', base], background=True,
                                exclusive=False))
        elif linux == 'skip' and not sys.platform.startswith('linux'):
            checks.append(Check('ci-lint-linux', 'ci-lint', 'CI Lint job on Ubuntu (make ci-lint)', [],
                                skip_reason='--no-linux', incomplete=True))
    if swift and not environment.IS_MAC:
        checks.append(Check('apple-build', 'swift', 'macOS job: SwiftPM build and unit tests', [],
                            skip_reason='macOS only; CI runs it'))
    elif swift:
        checks.append(Check('apple-build', 'swift', 'macOS job: SwiftPM build incl. tests',
                            ['swift', 'build', '--build-tests', *scratch], env=test_env, requires='swift',
                            forbid_drift=('Package.resolved',), lane='swift', mirror=True))
        skipped = sorted({Path(f).parts[1] for f in swift_changes if Path(f).parts[1] in UI_TEST_TARGETS})
        if skipped:
            print(f'pre-pr: never runs UI test targets: {", ".join(skipped)} (CI covers them)')
        graph = swift_tests.load_graph(False)
        if graph is None:
            checks.append(Check('apple-unit-tests', 'swift', 'macOS job: unit tests', [],
                                failure='swift package dump-package failed, so no tests could be selected'))
        else:
            if full:
                every = [t for t in graph.test_targets() if t not in CI_MACOS_SKIP_TARGETS]
                selection = Selection([f'^({"|".join(every)})\\.'], set(every))
            elif quick:
                selection = select_tests(swift_changes, False, graph, exclude=CI_MACOS_SKIP_TARGETS)
            else:
                selection = ci_macos_tests(files, graph)
            if selection.filters:
                checks.append(Check('apple-unit-tests', 'swift', test_title(selection, 'macOS job:'),
                                    ['python3', 'scripts/with-test-keychain.py', 'swift', 'test', '--skip-build',
                                     *scratch, '--filter', '|'.join(selection.filters)],
                                    env=test_env, requires='swift', counts_tests=True, lane='swift',
                                    mirror=True))
            graphs = [g for g in (graph, swift_tests.load_graph(True) if swift_changes else None) if g]
            missing = uncovered_modules(swift_changes, graphs)
            if missing:
                checks.append(Check('swift-test-coverage', 'swift', 'Every changed Swift module has unit tests', [],
                                    failure=f'no unit-test target covers {", ".join(missing)}; add tests for it'))
    if windows:
        checks.append(Check('windows-typecheck', 'windows', 'Windows Swift type check',
                            ['bash', 'scripts/ci/typecheck-windows-swift.sh'],
                            env={'SPEAK_WINDOWS_TYPECHECK_DIR': str(environment.OUT / 'windows-typecheck')},
                            # The executable target links Win32 libraries under Xcode's toolchain;
                            # CI runs this check on Linux (linux.yml); Portable Swift (Linux) covers the shared graph.
                            skip_reason='' if sys.platform.startswith('linux') else 'Linux only; CI runs it'))
    if api:
        # The Public API compatibility job's own script, against the merge base (CI's PR baseline).
        title = 'Public API compatibility (scripts/ci-api-compatibility.sh)'
        if environment.IS_MAC:
            env = environment.pr_title_env()
            if any(c.id == 'ci-lint' for c in checks):
                env['JSTI_API_SELFTEST'] = '0'  # make ci-lint's test-tooling already runs the gate's own tests
            checks.append(Check('api-compatibility', 'public-api', title,
                                ['bash', 'scripts/ci-api-compatibility.sh', environment.merge_base_or(base)],
                                env=env, requires='swift', forbid_drift=('Package.resolved',), mirror=True))
        else:
            checks.append(Check('api-compatibility', 'public-api', title, [], skip_reason='macOS only',
                                incomplete=True))
    owned = quality().classify(files)
    linted = sorted({f for kind in ('swift', 'python', 'shell', 'workflows') for f in owned[kind]})
    if linted:
        # Zero violations, as CI's Lint job enforces with `scripts/quality check --all`.
        kinds = ', '.join(k for k in ('swift', 'python', 'shell', 'workflows') if owned[k])
        checks.append(Check('quality', 'quality', f'Code quality: scripts/quality check ({kinds})',
                            ['python3', 'scripts/quality', 'check', *linted], exclusive=False))
    if android:
        # The Android CI job's script. Locally only with a working JDK and an approved feed
        # (android/settings.gradle.kts refuses public registries off GitHub-hosted runners);
        # otherwise on a remote precheck/** branch. Never a skip.
        title = 'Android CI job (scripts/ci-android.sh)'
        if environment.android_runs_locally():
            checks.append(Check('android', 'android', title, ['bash', 'scripts/ci-android.sh']))
        else:
            checks.append(Check('android', 'android', f'{title}, remote',
                                ['python3', 'scripts/linux-precheck', '--job', 'android',
                                 '--tree', str(environment.ROOT), '--base', base], background=True,
                                exclusive=False))
    if worker:
        directory = environment.ROOT / 'workers' / 'paid-access'
        checks.append(Check('worker-install', 'paid-access-worker', 'npm ci',
                            ['npm', 'ci', '--no-audit', '--no-fund'], cwd=directory, requires='npm',
                            exclusive=False))
        for script in ('typecheck', 'lint', 'test'):
            checks.append(Check(f'worker-{script}', 'paid-access-worker', f'npm run {script}',
                                ['npm', 'run', script], cwd=directory, requires='npm', exclusive=False))
    if landing:
        checks.append(Check('landing-tests', 'landing-page', 'Landing page tests', ['npm', 'test'],
                            cwd=environment.ROOT / 'landing-page', requires='npm', exclusive=False))
    checks.sort(key=lambda check: (not check.background, COST.get(check.id, 3)))
    return checks, areas
