#!/usr/bin/env python3
"""The packaged application-error query (native_execution_events).

Unit tests for verify-native-execution.py; Windows process calls are faked.
"""
import base64
import contextlib
import io
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import types
import unittest
from unittest import mock

HERE = pathlib.Path(__file__).resolve().parent
sys.dont_write_bytecode = True
sys.path.insert(0, str(HERE))
import native_execution_debugger as DEBUGGER  # noqa: E402
import native_execution_events as EVENTS  # noqa: E402
import native_execution_run as RUN  # noqa: E402
from native_execution_fakes import (  # noqa: E402
    NATIVE,
    StandaloneRequests,
)


class PackagedApplicationErrorTests(unittest.TestCase):
    def request(self, **changes):
        value = dict(schema=1, architecture="arm64", label="base-ui-smoke-test", exitCode=-1073741819,
                     originalPid=4242, parentPid=123, startedUTC="2026-10-28T12:00:00Z",
                     endedUTC="2026-10-28T12:00:02Z", executable=r"C:\Owned\SpeakWindows.exe",
                     expectedSHA256="0" * 64, powershell=r"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe",
                     powershellSHA256="1" * 64, startedTicks=1000, endedTicks=3000,
                     originalDeadlineTicks=61000, deadlineTicks=11000, frequency=1000)
        return dict(value, **changes)

    def encode(self, value):
        return base64.urlsafe_b64encode(json.dumps(value).encode("utf-8")).decode("ascii").rstrip("=")

    def event(self, **changes):
        data = dict(AppName="SpeakWindows.exe", AppPath=self.request()["executable"], ProcessId="4242",
                    ModuleName="PRIVATE_EVENT_CANARY.dll", ModuleVersion="1.2.3.4",
                    ExceptionCode="c0000005", FaultingOffset="00000123")
        data.update(changes)
        return dict(time="2026-10-28T12:00:01Z", data=data)

    def operate(self, value=None, runner=None, api=None, identity=None):
        api = api or types.SimpleNamespace(frequency=lambda: 1000, ticks=lambda: 3000, admitted=lambda _: True)
        runner = runner or (lambda *a, **k: dict(status="complete", cleanup="clean", exitCode=0,
            output=json.dumps(dict(status="ok", events=[self.event()])).encode("utf-8")))
        identity = identity or (lambda path, *a: (path, "same"))
        with mock.patch.dict(os.environ, {"SystemRoot": r"C:\Windows"}):
            return EVENTS.packaged_application_error(self.encode(value or self.request()),
                api_factory=lambda: api, runner=runner, identity=identity)

    def test_exact_event_only_request_and_long_original_span_do_not_widen_standalone(self):
        value = self.request(endedUTC="2026-10-28T12:00:59Z")
        self.assertEqual(EVENTS.packaged_event_request(self.encode(value)), value)
        old = StandaloneRequests().request(endedUTC=value["endedUTC"])
        with self.assertRaises(ValueError):
            DEBUGGER.diagnostic_request(self.encode(old))

    def test_closed_request_all_unknown_missing_duplicate_and_oversize_refuse_without_query(self):
        runner = mock.Mock()
        for key in self.request():
            value = self.request(); value.pop(key)
            self.assertNotEqual(self.operate(value=value, runner=runner)["status"], "observed")
        self.assertEqual(self.operate(self.request(extra="PRIVATE_EVENT_CANARY"), runner)["status"], "invalid")
        for raw in (b'{"schema":1,"schema":1}', b'\xff', b' ' * 8193):
            encoded = base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")
            self.assertEqual(EVENTS.packaged_application_error(encoded)["status"], "invalid")
        runner.assert_not_called()

    def test_foreign_target_contracts_and_unsigned_or_unknown_exits_refuse_before_identity(self):
        identity, runner = mock.Mock(), mock.Mock()
        changes = [dict(schema=True), dict(exitCode=3221225477), dict(exitCode=0), dict(exitCode=42),
                   dict(architecture="x64"), dict(label="ui-smoke"), dict(originalPid=True), dict(parentPid=-1),
                   dict(executable=r"C:\Owned\other.exe"), dict(executable=r"C:\Owned\..\SpeakWindows.exe"),
                   dict(executable=r"\\server\SpeakWindows.exe"), dict(executable=r"C:\Owned\SpeakWindows.exe:ads"),
                   dict(expectedSHA256="F" * 64), dict(powershell=r"C:\Owned\powershell.exe"),
                   dict(startedUTC="2026-10-28T12:00:00"), dict(endedUTC="2026-10-28T12:01:01Z"),
                   dict(endedUTC="2026-10-28T11:59:59Z"), dict(frequency=True), dict(frequency=1000000001),
                   dict(startedTicks=2), dict(endedTicks=999), dict(originalDeadlineTicks=61001),
                   dict(deadlineTicks=62000)]
        for change in changes:
            with self.subTest(change=tuple(change)):
                self.assertEqual(self.operate(self.request(**change), runner=runner, identity=identity)["status"], "invalid")
        identity.assert_not_called(); runner.assert_not_called()

    def test_job_membership_clock_frequency_and_ended_tick_checks_precede_image_reads(self):
        identity, runner = mock.Mock(), mock.Mock()
        for frequency, now, admitted in ((999, 3000, True), (1000, 2000, True), (1000, 11001, True),
                                          (1000, 3000, False), (1000, 0, True)):
            api = types.SimpleNamespace(frequency=lambda: frequency, ticks=lambda: now, admitted=lambda _: admitted)
            self.assertNotEqual(self.operate(api=api, identity=identity, runner=runner)["status"], "observed")
        identity.assert_not_called(); runner.assert_not_called()

    def test_budget_consumed_by_image_admission_prevents_event_launch(self):
        clock = [3000]
        api = types.SimpleNamespace(frequency=lambda: 1000, ticks=lambda: clock[0], admitted=lambda _: True)
        def identity(*args):
            clock[0] = 6000
            return "snapshot"
        runner = mock.Mock()
        self.assertEqual(self.operate(api=api, identity=identity, runner=runner)["status"], "deadline")
        runner.assert_not_called()

    def test_one_fixed_query_returns_only_closed_original_event_and_no_replay(self):
        calls = []
        def query(argv, environment, directory, budget, seconds, **kwargs):
            calls.append(argv)
            self.assertEqual(argv, [self.request()["powershell"], "-NoLogo", "-NoProfile", "-NonInteractive",
                                    "-Command", RUN.APPLICATION_ERROR_QUERY])
            self.assertEqual(seconds, 5)
            self.assertEqual((environment["JSTI_EVENT_START"], environment["JSTI_EVENT_END"]),
                             (self.request()["startedUTC"], self.request()["endedUTC"]))
            self.assertNotIn("PRIVATE_PARENT_CANARY", environment)
            return dict(status="complete", cleanup="clean", exitCode=0,
                        output=json.dumps(dict(status="ok", events=[self.event()])).encode("utf-8"))
        with mock.patch.dict(os.environ, {"PRIVATE_PARENT_CANARY": "secret"}), \
                mock.patch.object(DEBUGGER, "cdb_commands", side_effect=AssertionError("no debugger")):
            result = self.operate(runner=query)
        self.assertEqual(len(calls), 1)
        self.assertEqual(result, dict(schema=1, status="observed", cleanup="clean", applicationError=dict(
            status="observed", module="unknown", version="1.2.3.4", exceptionCode="0xc0000005",
            faultOffset="0x0000000000000123")))
        self.assertNotIn("PRIVATE", json.dumps(result)); self.assertNotIn("timeUTC", json.dumps(result))

    def test_pid_path_time_and_multiple_event_matching_is_not_broadened(self):
        cases = [([self.event(ProcessId="4243")], "no-match"),
                 ([self.event(AppPath=r"C:\Elsewhere\SpeakWindows.exe")], "no-match"),
                 ([dict(self.event(), time="2026-10-28T12:00:03Z")], "no-match"),
                 ([self.event(ExceptionCode="c0000409")], "invalid"),
                 ([self.event(), self.event()], "ambiguous")]
        for events, expected in cases:
            query = lambda *a, **k: dict(status="complete", cleanup="clean", exitCode=0,
                                        output=json.dumps(dict(status="ok", events=events)).encode("utf-8"))
            result = self.operate(runner=query)
            self.assertEqual(result["applicationError"], dict(status=expected))
            self.assertNotEqual(result["status"], "observed")

    def test_bad_output_error_timeout_cap_and_failed_cleanup_never_publish_observed(self):
        for event in [dict(status="complete", cleanup="clean", exitCode=0, output=b"PRIVATE_CANARY"),
                      dict(status="complete", cleanup="clean", exitCode=0, output=b"x" * 65537),
                      dict(status="complete", cleanup="clean", exitCode=0, output=b'{"status":"ok","status":"ok","events":[]}'),
                      dict(status="complete", cleanup="clean", exitCode=42, output=b"PRIVATE_CANARY"),
                      dict(status="deadline", cleanup="clean", exitCode=None, output=b"PRIVATE_CANARY"),
                      dict(status="truncated", cleanup="clean", exitCode=0, output=b"PRIVATE_CANARY"),
                      dict(status="complete", cleanup="failed", exitCode=0, output=b"PRIVATE_CANARY")]:
            result = self.operate(runner=lambda *a, **k: event)
            self.assertNotEqual(result["status"], "observed")
            self.assertNotIn("PRIVATE", json.dumps(result))
            self.assertNotIn("debugger", result)

    def test_image_changes_after_query_discard_observation(self):
        calls = []
        def identity(path, *args):
            calls.append(path)
            return path, len(calls) > 2
        self.assertNotEqual(self.operate(identity=identity)["status"], "observed")
        self.assertGreater(len(calls), 2)

    def test_private_scratch_cleanup_failure_disposes_observed_receipt(self):
        with tempfile.TemporaryDirectory() as directory:
            scratch = types.SimpleNamespace(name=directory, cleanup=mock.Mock(side_effect=OSError("PRIVATE_CANARY")))
            for runner in (None, lambda *a, **k: dict(status="complete", cleanup="clean", exitCode=0,
                                                      output=b"x" * 65537)):
                with mock.patch.object(tempfile, "TemporaryDirectory", return_value=scratch):
                    result = self.operate(runner=runner)
                self.assertEqual(result, EVENTS.packaged_event_result("unavailable", "failed"))

    def test_internal_dispatch_never_routes_event_only_to_legacy_or_debugger(self):
        with mock.patch.object(NATIVE, "main", side_effect=AssertionError("legacy")), \
                mock.patch.object(NATIVE, "standalone_main", side_effect=AssertionError("debugger")), \
                contextlib.redirect_stdout(io.StringIO()) as output:
            NATIVE.dispatch_main(["packaged-application-error", "--wrong", "PRIVATE_CANARY"])
        result = json.loads(output.getvalue())
        self.assertEqual(result, EVENTS.packaged_event_result("invalid"))
        self.assertLess(len(output.getvalue()), 8192)

    @unittest.skipUnless(shutil.which("pwsh"), "pure PowerShell projector needs pwsh")
    def test_actual_event_json_passes_actual_ps_projection_and_private_unknown_fields_refuse(self):
        projection = self.operate()
        with tempfile.TemporaryDirectory() as directory:
            script = pathlib.Path(directory) / "projection.ps1"
            script.write_text(". '" + str(HERE / "FailureDiagnostics.ps1").replace("'", "''") + "'\n" +
                "$v=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('" +
                base64.b64encode(json.dumps(projection).encode("utf-8")).decode("ascii") + "'))|ConvertFrom-Json\n" +
                "$safe=ConvertTo-JstiPackagedEventProjection $v\n" +
                "if($safe.applicationError.faultOffset -cne '0x0000000000000123'){throw 'projection'}\n" +
                "foreach($key in @('debugger','frames','private')){\n" +
                "$v|Add-Member -NotePropertyName $key -NotePropertyValue 'PRIVATE_CANARY'\n" +
                "$refused=$false;try{$null=ConvertTo-JstiPackagedEventProjection $v}catch{$refused=$true}\n" +
                "if(-not $refused){throw 'unknown field'};$v.PSObject.Properties.Remove($key)}\n" +
                "if('JstiDiagnosticNative' -as [type]){throw 'native load'}\n", encoding="utf-8")

            script.write_text(script.read_text(encoding="utf-8") + r"""
$script:eventProjection=$v
function Get-JstiDiagnosticIdentity { param($path,$names,[switch]$FrameworkPath)
 if(-not $FrameworkPath){throw 'framework option'};return @{Path=$path;Hash='0'*64} }
function New-JstiDiagnosticAdapter { param($frequency,$state);$script:eventState=$state;return @{} }
function Invoke-JstiDiagnosticBootstrap { param($adapter,$launch,[long]$cutoff,[long]$frequency)
 if($launch.Arguments[3] -cne 'packaged-application-error'){throw 'mode'}
 $bytes=[Text.Encoding]::UTF8.GetBytes(($script:eventProjection|ConvertTo-Json -Depth 8 -Compress))
 $script:eventState.Output.Write($bytes,0,$bytes.Length)
 return @{status='finished';cleanup='complete'} }
$env:SystemRoot='C:\Windows';$systemRoot=$env:SystemRoot;$isolatedPath='C:\Windows\System32'
$workspace=[IO.Path]::GetDirectoryName($PSCommandPath)
$f=[Diagnostics.Stopwatch]::Frequency;$t=[Diagnostics.Stopwatch]::GetTimestamp()
$ctx=@{originalPid=4242;startedUTC=[datetime]::UtcNow.AddSeconds(-2);endedUTC=[datetime]::UtcNow.AddSeconds(-1)
 startedTicks=$t-2*$f;endedTicks=$t-$f;originalDeadlineTicks=$t+58*$f;frequency=$f}
$setup=@{Host=@{Path='C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe';Hash='0'*64}
 Python=@{Path='C:\Owned\python.exe';Hash='0'*64}}
$run=@{label='base-ui-smoke-test';arguments='--ui-smoke-test';exitCode=-1073741819
 packageFullName='owned';identityError=$null;modules=@{passed=$true}}
$before=$run|ConvertTo-Json -Depth 8 -Compress
$receipt=Invoke-JstiPackagedEventDiagnostic $setup $run $ctx 'C:\Owned\SpeakWindows.exe' ('0'*64) 'owned'
if($receipt.status -cne 'observed' -or $receipt.applicationErrorEvidence.applicationError.faultOffset -cne '0x0000000000000123'){throw 'wrapper interop'}
if(($run|ConvertTo-Json -Depth 8 -Compress) -cne $before){throw 'original changed'}
if('JstiDiagnosticNative' -as [type]){throw 'native load'}
""", encoding="utf-8")
            result = subprocess.run([shutil.which("pwsh"), "-NoProfile", "-NonInteractive", "-File", str(script)],
                                    capture_output=True, timeout=60, check=False)
            self.assertEqual(result.returncode, 0, result.stderr.decode("utf-8", errors="replace"))


if __name__ == "__main__":
    unittest.main()
