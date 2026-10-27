import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("notarize_with_recovery", ROOT / "scripts/notarize-with-recovery.py")
HELPER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HELPER)
SUBMISSION = "bb9703b9-c48b-4ae2-a79d-5a95cc8897f1"
CREDENTIALS = {
    "APPLE_ID": "fixture@example.invalid", "APPLE_ID_PASSWORD": "fixture-password", "APPLE_TEAM_ID": "FIXTURETEAM",
}


def response(status, *, identifier=SUBMISSION):
    return subprocess.CompletedProcess([], 0, json.dumps({"id": identifier, "status": status}), "")


def uploaded():
    return subprocess.CompletedProcess([], 0, json.dumps({"id": SUBMISSION}), "")


def offline(code=-1009):
    return subprocess.CompletedProcess([], 1, "", f"Error Domain=NSURLErrorDomain Code={code} no network route")


class NotarizationRecoveryTests(unittest.TestCase):
    def run_helper(self, results, *, seconds=3600, attempts=120, interval=30, durations=None, credentials=None):
        calls = []
        sleeps = []
        now = [0.0]
        output = io.StringIO()
        results = iter(results)
        durations = iter(durations or [])

        def execute(arguments, **kwargs):
            calls.append((arguments, kwargs))
            now[0] += next(durations, 0)
            result = next(results)
            if isinstance(result, Exception):
                raise result
            return result

        def sleep(duration):
            sleeps.append(duration)
            now[0] += duration

        with patch.dict(HELPER.os.environ, CREDENTIALS if credentials is None else credentials, clear=True), \
             patch.object(HELPER.subprocess, "run", side_effect=execute), \
             patch.object(HELPER.time, "monotonic", side_effect=lambda: now[0]), \
             patch.object(HELPER.time, "sleep", side_effect=sleep), \
             contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            result = HELPER.notarize("fixture.dmg", seconds, attempts, interval)
        return result, calls, sleeps, output.getvalue()

    def test_successful_upload_is_submitted_once_then_queried_by_exact_uuid(self):
        code, calls, sleeps, _ = self.run_helper([uploaded(), response("Accepted")])
        self.assertEqual(code, 0)
        self.assertEqual([call[0][2] for call in calls], ["submit", "info"])
        self.assertIn("--no-wait", calls[0][0])
        self.assertNotIn("--wait", calls[0][0])
        self.assertEqual(calls[0][1]["timeout"], 3600)
        self.assertEqual(calls[1][0][3], SUBMISSION)
        self.assertEqual(sleeps, [])

    def test_observed_offline_and_connection_loss_recover_without_resubmission_or_deadline_reset(self):
        code, calls, sleeps, _ = self.run_helper([uploaded(), offline(-1009), offline(-1005), response("Accepted")])
        self.assertEqual(code, 0)
        self.assertEqual([call[0][2] for call in calls], ["submit", "info", "info", "info"])
        self.assertEqual({call[0][3] for call in calls[1:]}, {SUBMISSION})
        self.assertEqual([call[1]["timeout"] for call in calls[1:]], [3600, 3570, 3540])
        self.assertEqual(sleeps, [30, 30])

    def test_transient_query_consumes_the_original_attempt_limit(self):
        code, calls, sleeps, _ = self.run_helper([uploaded(), offline(), offline()], attempts=2)
        self.assertEqual(code, 1)
        self.assertEqual(len(calls), 3)
        self.assertEqual(sleeps, [30])

    def test_query_and_retry_delay_cannot_extend_the_single_wall_deadline(self):
        code, calls, sleeps, _ = self.run_helper([uploaded(), offline()], seconds=10, durations=[2, 3])
        self.assertEqual(code, 1)
        self.assertEqual(len(calls), 2)
        self.assertEqual(calls[1][1]["timeout"], 10)
        self.assertEqual(sleeps, [7])

    def test_accepted_response_after_deadline_is_not_a_success(self):
        code, calls, _, _ = self.run_helper([uploaded(), response("Accepted")], seconds=10, durations=[0, 10])
        self.assertEqual(code, 1)
        self.assertEqual(calls[1][1]["timeout"], 10)

    def test_request_timeout_fails_without_restarting_or_resubmitting(self):
        code, calls, _, _ = self.run_helper([uploaded(), subprocess.TimeoutExpired("fixture", 10)], seconds=10)
        self.assertEqual(code, 1)
        self.assertEqual(len(calls), 2)

    def test_final_allowed_attempt_can_accept_without_an_extra_request(self):
        code, calls, _, _ = self.run_helper([uploaded(), response("In Progress"), response("Accepted")], attempts=2)
        self.assertEqual(code, 0)
        self.assertEqual(len(calls), 3)

    def test_cli_retains_45_minute_window_and_uses_only_remaining_time(self):
        code, calls, sleeps, _ = self.run_helper([uploaded(), response("In Progress")], seconds=2700,
                                                attempts=90, durations=[0, 2695])
        self.assertEqual(code, 1)
        self.assertEqual(calls[0][1]["timeout"], 2700)
        self.assertEqual(calls[1][1]["timeout"], 2700)
        self.assertEqual(sleeps, [5])

    def test_upload_timeout_is_bounded_single_submit_without_polling_or_secret_diagnostics(self):
        for seconds in (3600, 2700):
            with self.subTest(seconds=seconds):
                private = " ".join(CREDENTIALS.values())
                timeout = subprocess.TimeoutExpired(["xcrun", private], seconds, output=private, stderr=private)
                code, calls, sleeps, output = self.run_helper([timeout], seconds=seconds)
                self.assertEqual(code, 1)
                self.assertEqual(len(calls), 1)
                self.assertEqual(calls[0][0][2], "submit")
                self.assertEqual(calls[0][1]["timeout"], seconds)
                self.assertEqual(sleeps, [])
                self.assertIn("acceptance unknown, refusing to resubmit", output)
                for value in CREDENTIALS.values():
                    self.assertNotIn(value, output)

    def test_invalid_and_rejected_are_terminal_and_preserve_diagnostics_for_same_id(self):
        for state in ("Invalid", "Rejected"):
            with self.subTest(state=state):
                log = subprocess.CompletedProcess([], 0, "fixture notarization failure details", "")
                code, calls, sleeps, output = self.run_helper([uploaded(), response(state), log])
                self.assertEqual(code, 1)
                self.assertEqual([call[0][2] for call in calls], ["submit", "info", "log"])
                self.assertEqual(calls[-1][0][3], SUBMISSION)
                self.assertEqual(sleeps, [])
                self.assertIn("fixture notarization failure details", output)

    def test_authentication_unknown_status_malformed_json_and_foreign_id_fail_closed(self):
        cases = [
            subprocess.CompletedProcess([], 1, "", "HTTPError(statusCode: 401) NSURLErrorDomain Code=-1009"),
            response("Unexpected"), response("Accepted", identifier="11111111-1111-1111-1111-111111111111"),
            subprocess.CompletedProcess([], 0, "status: Accepted", ""),
        ]
        for result in cases:
            with self.subTest(result=result):
                code, calls, sleeps, _ = self.run_helper([uploaded(), result])
                self.assertEqual(code, 1)
                self.assertEqual(len(calls), 2)
                self.assertEqual(sleeps, [])

    def test_upload_failure_or_invalid_id_never_retries_submit_or_queries(self):
        cases = [offline(), subprocess.CompletedProcess([], 0, '{"id": "bad-id"}', ""),
                 subprocess.CompletedProcess([], 0, '{"id": 123}', ""),
                 subprocess.CompletedProcess([], 0, "{}", "")]
        for result in cases:
            with self.subTest(result=result):
                code, calls, sleeps, _ = self.run_helper([result])
                self.assertEqual(code, 1)
                self.assertEqual(len(calls), 1)
                self.assertEqual(sleeps, [])

    def test_error_diagnostics_do_not_print_authentication_values(self):
        diagnostic = "bad credentials " + " ".join(CREDENTIALS.values())
        code, _, _, output = self.run_helper([uploaded(), subprocess.CompletedProcess([], 1, "", diagnostic)])
        self.assertEqual(code, 1)
        for value in CREDENTIALS.values():
            self.assertNotIn(value, output)

    def test_missing_credentials_fail_before_any_subprocess(self):
        with self.assertRaises(ValueError):
            self.run_helper([], credentials={})

    def test_actions_retain_limits_and_validation_order(self):
        package = (ROOT / ".github/actions/package-mac-release/action.yml").read_text()
        cli = (ROOT / ".github/actions/publish-speak-cli/action.yml").read_text()
        workflow = (ROOT / ".github/workflows/release-mac.yml").read_text()
        self.assertEqual(package.count("--timeout-seconds 3600 --max-attempts 120"), 2)
        self.assertIn("new, tighter per-submission cap", package)
        self.assertIn("--timeout-seconds 2700 --max-attempts 90", cli)
        self.assertIn("timeout-minutes: 240", workflow)
        helper = (ROOT / "scripts/notarize-with-recovery.py").read_text()
        self.assertIn("NEW tighter cap equal to the caller's polling window", helper)
        self.assertIn("separate post-upload polling window", helper)
        self.assertNotIn("notarytool submit", package + cli)
        for artifact in ("APP_PATH", "DMG_PATH"):
            invocation = (f'python3 scripts/notarize-with-recovery.py "${artifact}"'
                          if artifact == "DMG_PATH" else 'python3 scripts/notarize-with-recovery.py "$WORK/')
            self.assertLess(package.index(invocation), package.index(f'bash scripts/retry-staple.sh "${artifact}"'))
        self.assertLess(cli.index("python3 scripts/notarize-with-recovery.py"),
                        cli.index("- name: Verify speak archives"))
        self.assertIn("spctl --assess --type execute", package)
        self.assertIn("Verify Sparkle installation before publication", workflow)


if __name__ == "__main__":
    unittest.main()
