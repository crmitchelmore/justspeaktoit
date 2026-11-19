"""Offline tests for scripts/linux-precheck: the snapshot it pushes and the merge it tests."""
import importlib.machinery
import importlib.util
import io
import json
import os
import subprocess
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
_loader = importlib.machinery.SourceFileLoader('linux_precheck', str(ROOT / 'scripts' / 'linux-precheck'))
_spec = importlib.util.spec_from_loader('linux_precheck', _loader)
precheck = importlib.util.module_from_spec(_spec)
sys.modules['linux_precheck'] = precheck
_loader.exec_module(precheck)


def git(repo, *args):
    return subprocess.run(['git', *args], cwd=repo, check=True, text=True, capture_output=True).stdout.strip()


class SnapshotTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self.tmp.name)
        git(self.repo, 'init', '-q', '-b', 'main')
        git(self.repo, 'config', 'user.email', 't@example.com')
        git(self.repo, 'config', 'user.name', 't')
        (self.repo / '.gitignore').write_text('ignored.txt\n')
        (self.repo / 'a.txt').write_text('one\n')
        git(self.repo, 'add', '.')
        git(self.repo, 'commit', '-q', '-m', 'base')
        self.base = git(self.repo, 'rev-parse', 'HEAD')

    def tearDown(self):
        self.tmp.cleanup()

    def files(self, sha):
        return sorted(git(self.repo, 'ls-tree', '-r', '--name-only', sha).splitlines())

    def test_snapshot_holds_uncommitted_and_untracked_files_and_the_ci_overlay(self):
        (self.repo / 'a.txt').write_text('two\n')
        (self.repo / 'new.txt').write_text('new\n')
        (self.repo / 'ignored.txt').write_text('x\n')
        sha = precheck.snapshot(self.repo)
        self.assertEqual(git(self.repo, 'show', f'{sha}:a.txt'), 'two')
        self.assertIn('new.txt', self.files(sha))
        self.assertNotIn('ignored.txt', self.files(sha))
        for path in precheck.OVERLAY:  # an old tree gets this checkout's precheck workflow and script
            self.assertIn(path, self.files(sha))
        self.assertEqual(git(self.repo, 'rev-parse', f'{sha}^'), self.base)
        self.assertEqual(git(self.repo, 'status', '--porcelain', '--untracked-files=no'), 'M a.txt',
                         'the real index is untouched')

    def test_the_snapshot_names_its_job_for_precheck_yml(self):
        sha = precheck.snapshot(self.repo, job='android')
        self.assertIn('[precheck:android]', git(self.repo, 'log', '-1', '--format=%s', sha))
        merged = precheck.merged_with(self.repo, sha, self.base, 'android')
        self.assertIn('[precheck:android]', git(self.repo, 'log', '-1', '--format=%s', merged))
        workflow = (ROOT / '.github' / 'workflows' / 'precheck.yml').read_text(encoding='utf-8')
        for job in precheck.JOBS:
            self.assertIn(f"'[precheck:{job}]'", workflow)

    def test_a_tree_that_has_its_own_script_keeps_it(self):
        script = self.repo / 'scripts' / 'ci-portable-linux.sh'
        script.parent.mkdir()
        script.write_text('# branch version\n')
        sha = precheck.snapshot(self.repo)
        self.assertEqual(git(self.repo, 'show', f'{sha}:scripts/ci-portable-linux.sh'), '# branch version')

    def test_merge_with_base_mirrors_the_pull_request_merge_commit(self):
        git(self.repo, 'checkout', '-q', '-b', 'feature')
        (self.repo / 'b.txt').write_text('feature\n')
        git(self.repo, 'add', '.')
        git(self.repo, 'commit', '-q', '-m', 'feature')
        git(self.repo, 'checkout', '-q', 'main')
        (self.repo / 'c.txt').write_text('main moved\n')
        git(self.repo, 'add', '.')
        git(self.repo, 'commit', '-q', '-m', 'main')
        main = git(self.repo, 'rev-parse', 'HEAD')
        git(self.repo, 'checkout', '-q', 'feature')
        merged = precheck.merged_with(self.repo, precheck.snapshot(self.repo), main)
        self.assertTrue({'b.txt', 'c.txt'} <= set(self.files(merged)))
        self.assertEqual(git(self.repo, 'rev-parse', f'{merged}^1'), main)

    def test_conflicting_change_fails_like_ci(self):
        git(self.repo, 'checkout', '-q', '-b', 'feature')
        (self.repo / 'a.txt').write_text('feature\n')
        git(self.repo, 'commit', '-q', '-am', 'feature')
        git(self.repo, 'checkout', '-q', 'main')
        (self.repo / 'a.txt').write_text('main\n')
        git(self.repo, 'commit', '-q', '-am', 'main')
        main = git(self.repo, 'rev-parse', 'HEAD')
        git(self.repo, 'checkout', '-q', 'feature')
        with self.assertRaises(SystemExit) as raised:
            precheck.merged_with(self.repo, precheck.snapshot(self.repo), main)
        self.assertIn('does not merge cleanly', str(raised.exception))



class PushRetryTests(unittest.TestCase):
    def test_rejected_push_is_retried_then_succeeds(self):
        outcomes = [SystemExit('rejected'), '']
        with mock.patch.object(precheck, 'git', side_effect=outcomes) as git, \
                mock.patch.object(precheck.time, 'sleep'):
            precheck.push(Path('.'), 'a' * 40, 'precheck/x', attempts=3)
        self.assertEqual(git.call_count, 2)

    def test_persistent_rejection_still_fails(self):
        with mock.patch.object(precheck, 'git', side_effect=SystemExit('rejected')) as git, \
                mock.patch.object(precheck.time, 'sleep'), self.assertRaises(SystemExit):
            precheck.push(Path('.'), 'a' * 40, 'precheck/x', attempts=3)
        self.assertEqual(git.call_count, 3)

    def test_cancellation_during_push_is_not_retried(self):
        with mock.patch.object(precheck, 'git', side_effect=SystemExit(143)) as git, \
                mock.patch.object(precheck.time, 'sleep'), self.assertRaises(SystemExit) as raised:
            precheck.push(Path('.'), 'a' * 40, 'precheck/x', attempts=3)
        self.assertEqual(raised.exception.code, 143)
        self.assertEqual(git.call_count, 1)


FAKE_RUNTIME = '''#!/usr/bin/env python3
import json, os, sys
with open(os.environ['FAKE_LOG'], 'a') as log:
    log.write(json.dumps(sys.argv[1:]) + '\\n')
if sys.argv[1:3] == ['volume', 'inspect']:
    sys.exit(1)
if sys.argv[1] == 'run':
    with open(os.environ['FAKE_TAR'], 'wb') as tar:
        tar.write(sys.stdin.buffer.read())
    sys.exit(int(os.environ.get('FAKE_CODE', '0')))
'''


class ContainerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.repo = self.dir / 'repo'
        self.repo.mkdir()
        git(self.repo, 'init', '-q', '-b', 'main')
        git(self.repo, 'config', 'user.email', 't@example.com')
        git(self.repo, 'config', 'user.name', 't')
        (self.repo / 'a.txt').write_text('one\n')
        git(self.repo, 'add', '.')
        git(self.repo, 'commit', '-q', '-m', 'base')
        (self.repo / 'new.txt').write_text('untracked\n')
        self.runtime = self.dir / 'container'
        self.runtime.write_text(FAKE_RUNTIME)
        self.runtime.chmod(0o755)
        env = {'FAKE_LOG': str(self.dir / 'log'), 'FAKE_TAR': str(self.dir / 'tar'), 'HOME': str(self.dir)}
        patcher = mock.patch.dict(os.environ, env)
        patcher.start()
        self.addCleanup(patcher.stop)

    def tearDown(self):
        self.tmp.cleanup()

    def calls(self):
        return [json.loads(line) for line in (self.dir / 'log').read_text().splitlines()]

    def test_apple_container_gets_the_snapshot_a_volume_and_resources(self):
        self.assertEqual(precheck.container(self.repo, str(self.runtime), 'main'), 0)
        calls = self.calls()
        self.assertEqual(calls[1][:3], ['volume', 'create', '-s'])
        run = next(c for c in calls if c[0] == 'run')
        self.assertIn('--cpus', run)
        self.assertIn('JSTI_SWIFT_TEST_PARALLEL=1', run)
        self.assertIn('jsti-portable-build:/build', run)
        self.assertEqual(calls[-1][:2], ['delete', '--force'])
        with tarfile.open(fileobj=io.BytesIO((self.dir / 'tar').read_bytes())) as tar:
            names = tar.getnames()
        self.assertIn('new.txt', names)
        self.assertIn('scripts/ci/sync-tree.py', names)

    def test_a_failed_run_fails(self):
        with mock.patch.dict(os.environ, {'FAKE_CODE': '1'}):
            self.assertEqual(precheck.container(self.repo, str(self.runtime), None), 1)

    def test_apple_container_is_found_when_docker_and_podman_are_absent(self):
        status = subprocess.CompletedProcess([], 0)
        with mock.patch.object(precheck.shutil, 'which', lambda name: '/bin/container' if name == 'container' else None), \
                mock.patch.object(precheck.subprocess, 'run', return_value=status) as run:
            self.assertEqual(precheck.container_runtime(), '/bin/container')
        run.assert_called_once_with(['/bin/container', 'system', 'status'], capture_output=True)


FAKE_SWIFT = """#!/bin/bash
echo "$*" >> "$FAKE_LOG"
case "$*" in
  *--parallel*) printf '%b\\n' "$FAKE_PARALLEL_OUT"; exit 1 ;;
  *--filter*) exit "${FAKE_RETRY:-0}" ;;
  'test --skip-build --scratch-path /s') exit "${FAKE_SERIAL:-0}" ;;
esac
"""


class PortableScriptTests(unittest.TestCase):
    """scripts/ci-portable-linux.sh's parallel mode: failures rerun serially and must pass there."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        (self.dir / 'scripts' / 'ci').mkdir(parents=True)
        (self.dir / 'bin').mkdir()
        script = self.dir / 'scripts' / 'ci-portable-linux.sh'
        script.write_text((ROOT / 'scripts' / 'ci-portable-linux.sh').read_text())
        (self.dir / 'scripts' / 'ci' / 'verify-portable-core-boundary.py').write_text('')
        for path, text in ((self.dir / 'scripts' / 'ci' / 'retry-network.sh', '#!/bin/bash\nexec "$@"\n'),
                           (self.dir / 'bin' / 'swift', FAKE_SWIFT)):
            path.write_text(text)
            path.chmod(0o755)

    def tearDown(self):
        self.tmp.cleanup()

    def run_script(self, parallel_out, **env):
        result = subprocess.run(['bash', str(self.dir / 'scripts' / 'ci-portable-linux.sh')], text=True,
                                capture_output=True,
                                env={**os.environ, 'PATH': f"{self.dir / 'bin'}:{os.environ['PATH']}",
                                     'FAKE_LOG': str(self.dir / 'log'), 'FAKE_PARALLEL_OUT': parallel_out,
                                     'JSTI_SWIFT_TEST_PARALLEL': '1', 'JSTI_SWIFT_TEST_WORKERS': '2',
                                     'JSTI_SCRATCH_PATH': '/s', **env})
        tests = [line.replace(' --scratch-path /s', '') for line in (self.dir / 'log').read_text().splitlines()
                 if line.startswith('test')]
        return result.returncode, tests

    def test_a_flaky_failure_passes_when_its_serial_rerun_passes(self):
        code, tests = self.run_script("Test Case 'Voice.testA' failed (0.2 seconds)")
        self.assertEqual(code, 0)
        self.assertEqual(tests[-1], 'test --skip-build --filter \\bVoice/testA$')

    def test_a_failure_that_repeats_serially_fails(self):
        code, _ = self.run_script("Test Case 'Voice.testA' failed (0.2 seconds)", FAKE_RETRY='1')
        self.assertEqual(code, 1)

    def test_an_unattributed_failure_reruns_everything_serially(self):
        code, tests = self.run_script('✘ Test thing() failed', FAKE_SERIAL='1')
        self.assertEqual(code, 1)
        self.assertEqual(tests[-1], 'test --skip-build')


if __name__ == '__main__':
    unittest.main()
