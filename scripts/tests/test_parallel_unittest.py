"""scripts/ci/parallel-unittest.py: a failure anywhere fails the run, and every test runs once."""
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

RUNNER = Path(__file__).resolve().parents[1] / 'ci' / 'parallel-unittest.py'

PASSING = '''
import unittest
class Fixture(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.ready = True
''' + ''.join(f'''
    def test_{n}(self):
        self.assertTrue(self.ready)
''' for n in range(7))


class ParallelUnittestTests(unittest.TestCase):
    def run_suite(self, files: dict[str, str], *args: str, retry: bool = False):
        with tempfile.TemporaryDirectory() as directory:
            for name, text in files.items():
                (Path(directory) / name).write_text(text, encoding='utf-8')
            return subprocess.run([sys.executable, str(RUNNER), '-s', directory, '-p', 'test_*.py', '-j', '3',
                                   *args], capture_output=True, text=True, timeout=120,
                                  env={**os.environ, 'JSTI_TEST_RETRY': '1' if retry else '0'})

    def test_every_test_runs_once_with_class_fixtures(self):
        result = self.run_suite({'test_a.py': PASSING}, '-v')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Ran 7 tests', result.stderr)
        self.assertEqual(result.stderr.count(' ... ok'), 7)

    def test_a_failure_fails_the_run_and_is_shown(self):
        failing = 'import unittest\nclass F(unittest.TestCase):\n    def test_x(self):\n        self.fail("boom")\n'
        result = self.run_suite({'test_a.py': PASSING, 'test_b.py': failing})
        self.assertEqual(result.returncode, 1)
        self.assertIn('boom', result.stderr)
        self.assertIn('Ran 8 tests', result.stderr)

    def test_a_module_that_cannot_import_fails_the_run(self):
        result = self.run_suite({'test_a.py': PASSING, 'test_b.py': 'import no_such_module_jsti\n'})
        self.assertEqual(result.returncode, 1)
        self.assertIn('no_such_module_jsti', result.stderr)

    def test_retry_passes_a_test_that_fails_only_once_and_names_it(self):
        flaky = ('import os, unittest\nclass F(unittest.TestCase):\n    def test_x(self):\n'
                 '        marker = os.path.join(os.path.dirname(__file__), "ran")\n'
                 '        first = not os.path.exists(marker)\n        open(marker, "w").close()\n'
                 '        self.assertFalse(first, "slow")\n')
        self.assertEqual(self.run_suite({'test_a.py': PASSING, 'test_b.py': flaky}).returncode, 1)
        result = self.run_suite({'test_a.py': PASSING, 'test_b.py': flaky}, retry=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('passed on a serial rerun', result.stderr)
        self.assertIn('test_b.F.test_x', result.stderr)

    def test_retry_reruns_the_parent_of_failed_subtests_once(self):
        flaky = ('import os, unittest\nclass F(unittest.TestCase):\n    def test_x(self):\n'
                 '        marker = os.path.join(os.path.dirname(__file__), "ran")\n'
                 '        first = not os.path.exists(marker)\n        open(marker, "w").close()\n'
                 '        for case in ("a", "b"):\n            with self.subTest(case=case):\n'
                 '                self.assertFalse(first, "slow")\n')
        result = self.run_suite({'test_b.py': flaky}, retry=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('rerunning 1 failed test(s)', result.stderr)

    def test_retry_still_fails_a_test_that_fails_again(self):
        failing = 'import unittest\nclass F(unittest.TestCase):\n    def test_x(self):\n        self.fail("boom")\n'
        self.assertEqual(self.run_suite({'test_b.py': failing}, retry=True).returncode, 1)

    def test_no_tests_is_a_failure(self):
        self.assertEqual(self.run_suite({'test_a.py': 'x = 1\n'}).returncode, 1)


if __name__ == '__main__':
    unittest.main()
