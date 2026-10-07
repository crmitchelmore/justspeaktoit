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
        if (timeout == 600 and self.timeout) or (
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
    def run_setup(self, *, boot_result=0, timeout=False, ignore=False):
        self.events = []
        self.boot = Boot(self.events, boot_result, timeout, ignore)

        def start(command):
            self.events.append(("boot", command))
            return self.boot

        with patch.object(MODULE.subprocess, "Popen", side_effect=start), patch.object(
            MODULE.subprocess, "run"
        ) as build:
            MODULE.prepare("simulator")
            build.assert_not_called()

    def test_boot_is_joined_without_compilation_or_project_generation(self):
        self.run_setup()
        self.assertEqual([entry[0] for entry in self.events], ["boot", "wait"])
        self.assertEqual(self.events[0][1], Boot.args)
        self.assertEqual(self.events[1], ("wait", 600))
        self.assertNotIn(("terminate",), self.events)

    def test_boot_failure_cannot_be_reported_as_ready(self):
        with self.assertRaises(subprocess.CalledProcessError):
            self.run_setup(boot_result=42)

    def test_readiness_timeout_fails_and_cleans_up_only_the_owned_process(self):
        with self.assertRaisesRegex(RuntimeError, "ten minutes"):
            self.run_setup(timeout=True)
        self.assertIn(("terminate",), self.events)
        self.assertEqual(self.boot.returncode, -15)

    def test_readiness_timeout_kills_boot_that_ignores_termination(self):
        with self.assertRaises(RuntimeError):
            self.run_setup(timeout=True, ignore=True)
        self.assertEqual(self.events[-4:], [("terminate",), ("wait", 5), ("kill",), ("wait", 5)])


if __name__ == "__main__":
    unittest.main()
