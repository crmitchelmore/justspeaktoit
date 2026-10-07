import importlib.util
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location(
    "prepare_ios_ci", Path(__file__).resolve().parents[1] / "prepare-ios-ci.py"
)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class Boot:
    args = ["xcrun", "simctl", "bootstatus", "simulator", "-b"]

    def __init__(self, events, result=0, timeout=False, ignore_termination=False):
        self.events = events
        self.result = result
        self.timeout = timeout
        self.ignore_termination = ignore_termination
        self.returncode = None

    def poll(self):
        return self.returncode

    def wait(self, timeout):
        self.events.append(("wait", timeout))
        if (timeout == 300 and self.timeout) or (
            self.ignore_termination and self.returncode is None
        ):
            raise subprocess.TimeoutExpired(self.args, timeout)
        self.returncode = self.result if self.returncode is None else self.returncode
        return self.returncode

    def terminate(self):
        self.events.append(("terminate",))
        if not self.ignore_termination:
            self.returncode = -15

    def kill(self):
        self.events.append(("kill",))
        self.returncode = -9


class PrepareIOSCITests(unittest.TestCase):
    def run_setup(self, *, failure=None, boot_result=0, timeout=False, ignore=False):
        self.events = []
        self.boot = Boot(self.events, boot_result, timeout, ignore)

        def start(command):
            self.events.append(("boot", command))
            return self.boot

        def run(command, **options):
            self.events.append((command[0], command, options))
            self.assertTrue(options["check"])
            if command[0] == failure:
                raise subprocess.CalledProcessError(42, command)

        with patch.object(MODULE.subprocess, "Popen", side_effect=start), patch.object(
            MODULE.subprocess, "run", side_effect=run
        ):
            MODULE.prepare("simulator")

    def test_boot_overlaps_project_generation_and_is_joined_before_success(self):
        self.run_setup()
        self.assertEqual([entry[0] for entry in self.events], ["boot", "tuist", "wait"])
        self.assertEqual(self.events[0][1], Boot.args)
        self.assertEqual(self.events[1][1], ["tuist", "generate", "--no-open"])
        self.assertEqual(self.events[1][2]["env"]["TUIST_IOS_KEYBOARD"], "1")
        self.assertEqual(self.events[2], ("wait", 300))
        self.assertNotIn(("terminate",), self.events)

    def test_project_failure_stops_owned_boot(self):
        with self.assertRaises(subprocess.CalledProcessError):
            self.run_setup(failure="tuist")
        self.assertIn(("terminate",), self.events)
        self.assertNotIn(("wait", 300), self.events)

    def test_boot_failure_cannot_be_reported_as_ready(self):
        with self.assertRaises(subprocess.CalledProcessError):
            self.run_setup(boot_result=42)

    def test_readiness_timeout_fails_and_cleans_up_only_the_owned_process(self):
        with self.assertRaisesRegex(RuntimeError, "five minutes after project generation"):
            self.run_setup(timeout=True)
        self.assertIn(("terminate",), self.events)
        self.assertEqual(self.boot.returncode, -15)

    def test_failed_build_kills_boot_that_ignores_termination(self):
        with self.assertRaises(subprocess.CalledProcessError):
            self.run_setup(failure="tuist", ignore=True)
        self.assertEqual(self.events[-4:], [("terminate",), ("wait", 5), ("kill",), ("wait", 5)])


if __name__ == "__main__":
    unittest.main()
