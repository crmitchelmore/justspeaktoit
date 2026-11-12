"""Tests for scripts/ci/lint-suppression-ratchet.py, the CI Lint job's SwiftLint suppression ratchet."""
import contextlib
import importlib.util
import io
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / 'ci' / 'lint-suppression-ratchet.py'
_spec = importlib.util.spec_from_file_location('lint_suppression_ratchet', SCRIPT)
ratchet = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ratchet)


class RatchetTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.git('init', '-q', '-b', 'main')
        self.write('A.swift', '// swiftlint:disable file_length\nlet a = 1\n')
        self.git('add', '.')
        self.git('commit', '-q', '-m', 'base')
        self.git('checkout', '-q', '-b', 'feature')

    def tearDown(self):
        self.directory.cleanup()

    def git(self, *args):
        subprocess.run(['git', '-c', 'user.email=t@example.com', '-c', 'user.name=T', '-c', 'core.hooksPath=/dev/null',
                        '-c', 'commit.gpgsign=false', *args], cwd=self.root, check=True, capture_output=True)

    def write(self, name, text):
        (self.root / name).write_text(text, encoding='utf-8')

    def run_ratchet(self):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            status = ratchet.main(['--base', 'main'], root=self.root)
        return status, out.getvalue() + err.getvalue()

    def test_unchanged_passes(self):
        status, output = self.run_ratchet()
        self.assertEqual(status, 0, output)
        self.assertIn('1 file-wide suppressions (+0', output)

    def test_new_file_wide_suppression_fails_even_when_untracked(self):
        self.write('B.swift', '// swiftlint:disable type_body_length line_length\n')
        status, output = self.run_ratchet()
        self.assertEqual(status, 1)
        self.assertIn('+1 type_body_length', output)
        self.assertIn('+1 line_length', output)

    def test_scoped_suppressions_are_not_counted(self):
        self.write('B.swift', 'let x = 1 // swiftlint:disable:this identifier_name\n'
                              '// swiftlint:disable:next force_cast\nlet y = z as! Int\n')
        self.assertEqual(self.run_ratchet()[0], 0)

    def test_suppression_that_moves_with_a_split_passes(self):
        self.write('A.swift', 'let a = 1\n')
        self.write('C.swift', '// swiftlint:disable file_length\n')
        self.assertEqual(self.run_ratchet()[0], 0)

    def test_a_baseline_file_fails(self):
        self.write(ratchet.BASELINE, '[]')
        status, output = self.run_ratchet()
        self.assertEqual(status, 1)
        self.assertIn('must not exist', output)

    def test_ci_lint_runs_the_ratchet_without_a_baseline(self):
        makefile = (Path(__file__).resolve().parents[2] / 'Makefile').read_text(encoding='utf-8')
        self.assertIn('python3 scripts/ci/lint-suppression-ratchet.py', makefile.split('\nci-lint:', 1)[1])
        self.assertNotIn('--baseline', makefile.split('\nlint:', 1)[1].split('\n\n', 1)[0])


if __name__ == '__main__':
    unittest.main()
