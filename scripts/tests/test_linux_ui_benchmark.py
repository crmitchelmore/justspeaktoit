import importlib.util
from pathlib import Path
import subprocess
import unittest
from unittest.mock import MagicMock, patch

SPEC = importlib.util.spec_from_file_location("benchmark", Path(__file__).resolve().parents[1] / "linux" / "linux-ui-benchmark.py")
BENCH = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BENCH)


class BenchmarkTests(unittest.TestCase):
    def test_bus_owner_without_windows_prevents_launch(self):
        with patch.object(BENCH.subprocess, "check_output", side_effect=["(true,)", "[]"]), \
                patch.object(BENCH.subprocess, "Popen") as launch:
            with self.assertRaisesRegex(RuntimeError, "Close Just Speak"):
                BENCH.benchmark(Path("app"))
            launch.assert_not_called()

    def test_query_timeout_terminates_owned_child(self):
        child = MagicMock(pid=42)
        child.poll.return_value = None
        with patch.object(BENCH.subprocess, "check_output", side_effect=[
                "(false,)", "[]", subprocess.TimeoutExpired("hyprctl", 2)]) as query, \
                patch.object(BENCH.subprocess, "Popen", return_value=child):
            with self.assertRaises(subprocess.TimeoutExpired):
                BENCH.benchmark(Path("app"))
            child.terminate.assert_called_once()
            child.wait.assert_called_once_with(timeout=10)
            self.assertTrue(all(0 < call.kwargs["timeout"] <= 2 for call in query.call_args_list))

    def test_warmup_is_excluded_from_samples_and_children_are_cleaned_up(self):
        child = MagicMock(pid=42)
        child.poll.return_value = None
        with patch.object(BENCH.subprocess, "check_output", side_effect=[
                "(false,)", "[]"] + ['[{"pid":42,"mapped":true}]'] * 3), \
                patch.object(BENCH.subprocess, "Popen", return_value=child) as launch, \
                patch.object(BENCH, "process_metrics", return_value=(0, 123)), \
                patch.object(BENCH.time, "sleep"):
            result = BENCH.benchmark(Path("app"), runs=2)
            self.assertEqual(launch.call_count, 3)
            self.assertEqual(child.terminate.call_count, 3)
            self.assertEqual(len(result["runs"]), 2)
            self.assertIsNone(result["runs"][0]["idle_cpu_percent_one_core"])
            self.assertEqual(result["runs"][1]["idle_cpu_percent_one_core"], 0)
