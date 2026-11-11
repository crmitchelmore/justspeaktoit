"""Tests for scripts/ci/lint-baseline-ratchet.py, the CI Lint job's SwiftLint baseline ratchet."""
import contextlib
import importlib.util
import io
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / 'ci' / 'lint-baseline-ratchet.py'
_spec = importlib.util.spec_from_file_location('lint_baseline_ratchet', SCRIPT)
ratchet = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ratchet)


def entries(*files):
    return [{'text': '', 'violation': {'location': {'file': name, 'line': i + 1}}} for i, name in enumerate(files)]


class RatchetTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.git('init', '-q', '-b', 'main')
        self.git('config', 'user.email', 'test@example.com')
        self.git('config', 'user.name', 'Test')
        self.commit(entries('A.swift', 'B.swift'))
        self.git('checkout', '-q', '-b', 'feature')

    def tearDown(self):
        self.directory.cleanup()

    def git(self, *args):
        subprocess.run(['git', '-c', 'core.hooksPath=/dev/null', '-c', 'commit.gpgsign=false', *args],
                       cwd=self.root, check=True, capture_output=True)

    def write(self, baseline):
        (self.root / ratchet.BASELINE).write_text(json.dumps(baseline), encoding='utf-8')

    def commit(self, baseline):
        self.write(baseline)
        self.git('add', ratchet.BASELINE)
        self.git('commit', '-q', '-m', 'baseline')

    def run_ratchet(self, *args):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            status = ratchet.main(['--base', 'main', *args], root=self.root)
        return status, out.getvalue() + err.getvalue()

    def test_unchanged_or_smaller_baseline_passes(self):
        self.assertEqual(self.run_ratchet()[0], 0)
        self.commit(entries('A.swift'))
        status, output = self.run_ratchet()
        self.assertEqual(status, 0)
        self.assertIn('-1 vs main', output)

    def test_growth_fails_and_names_the_files(self):
        self.commit(entries('A.swift', 'B.swift', 'B.swift', 'C.swift'))
        status, output = self.run_ratchet()
        self.assertEqual(status, 1)
        self.assertIn('grew from 2 to 4', output)
        self.assertIn('+1 B.swift', output)
        self.assertIn('+1 C.swift', output)

    def test_uncommitted_growth_fails(self):
        self.write(entries('A.swift', 'B.swift', 'C.swift'))
        self.assertEqual(self.run_ratchet()[0], 1)

    def test_compares_with_the_merge_base_not_the_moving_base(self):
        # main burns down after the branch point; the branch's own baseline is unchanged.
        self.git('checkout', '-q', 'main')
        self.commit(entries('A.swift'))
        self.git('checkout', '-q', 'feature')
        self.assertEqual(self.run_ratchet()[0], 0)

    def test_missing_base_fails_closed(self):
        status, output = self.run_ratchet('--base', 'no-such-branch')
        self.assertEqual(status, 1)
        self.assertIn('not available', output)

    def test_base_without_a_baseline_passes(self):
        self.git('checkout', '-q', '--orphan', 'empty')
        self.git('rm', '-q', '--cached', ratchet.BASELINE)
        self.git('commit', '-q', '--allow-empty', '-m', 'empty')
        self.git('checkout', '-q', '-f', 'feature')
        status, output = self.run_ratchet('--base', 'empty')
        self.assertEqual(status, 0)
        self.assertIn('nothing to ratchet against', output)

    def test_ci_lint_runs_the_ratchet(self):
        makefile = (Path(__file__).resolve().parents[2] / 'Makefile').read_text(encoding='utf-8')
        target = makefile.split('\nci-lint:', 1)[1].split('\n\n', 1)[0]
        self.assertIn('python3 scripts/ci/lint-baseline-ratchet.py', target)


if __name__ == '__main__':
    unittest.main()
