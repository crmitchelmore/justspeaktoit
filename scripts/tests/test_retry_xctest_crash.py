import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "retry-xctest-crash.py"
spec = importlib.util.spec_from_file_location("retry_xctest_crash", SCRIPT)
retry = importlib.util.module_from_spec(spec)
spec.loader.exec_module(retry)

CRASH = ("Test Case '-[A.B testOne]' passed (0.1 seconds).\n"
         "error: Process 'xctest X.xctest' exited with unexpected signal code 11\n"
         "Test Case '-[A.C testCrash]' started.\n")


class CrashDetectionTests(unittest.TestCase):
    def test_crash_without_failures_names_the_last_started_case(self):
        self.assertEqual(retry.crash_only(1, CRASH), ("11", "-[A.C testCrash]"))

    def test_ordinary_failures_and_successes_are_not_retried(self):
        self.assertIsNone(retry.crash_only(0, CRASH))
        self.assertIsNone(retry.crash_only(1, "Test Case '-[A.B testOne]' failed (0.1 seconds).\n"))
        self.assertIsNone(retry.crash_only(1, CRASH + "Test Case '-[A.D testTwo]' failed (0.2 seconds).\n"))


class RetryTests(unittest.TestCase):
    def command(self, directory, crashes):
        counter = Path(directory) / "count"
        program = (
            "import pathlib,sys\n"
            f"p=pathlib.Path({str(counter)!r});n=int(p.read_text()) if p.exists() else 0;p.write_text(str(n+1))\n"
            f"if n<{crashes}: print({CRASH!r});sys.exit(1)\n"
        )
        return [sys.executable, "-c", program], counter

    def test_a_single_crash_is_retried_once(self):
        with tempfile.TemporaryDirectory() as directory:
            command, counter = self.command(directory, 1)
            self.assertEqual(retry.main(command), 0)
            self.assertEqual(counter.read_text(), "2")

    def test_a_repeated_crash_still_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            command, counter = self.command(directory, 5)
            self.assertEqual(retry.main(command), 1)
            self.assertEqual(counter.read_text(), "2")


if __name__ == "__main__":
    unittest.main()
