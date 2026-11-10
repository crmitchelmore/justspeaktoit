"""Offline tests for scripts/linux-precheck: the snapshot it pushes and the merge it tests."""
import importlib.machinery
import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

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


if __name__ == '__main__':
    unittest.main()
