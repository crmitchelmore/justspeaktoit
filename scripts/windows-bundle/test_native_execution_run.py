#!/usr/bin/env python3
"""The run phase and the command line (native_execution_run, verify-native-execution.py).

Unit tests for verify-native-execution.py; Windows process calls are faked.
"""
import contextlib
import datetime
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
import native_execution_host as HOST  # noqa: E402
import native_execution_run as RUN  # noqa: E402
from native_execution_fakes import (  # noqa: E402
    AMD64,
    APP,
    ARM64,
    FIXTURES,
    NATIVE,
    PE,
    SYSTEM,
    Clock,
    FakeAPI,
    FakeProcess,
    native_image,
)


class ObservationTests(unittest.TestCase):
    def observe(self, api, process=None, timeout=60.0):
        return RUN.observe(process or FakeProcess(), api, clock=Clock(), sleep=lambda _: None, timeout=timeout)

    def test_native_arm64_process_passes_with_its_modules_recorded(self):
        api = FakeAPI(modules=[[APP] + SYSTEM, [APP] + SYSTEM + ["C:\\a\\swiftCore.dll", "C:\\a\\vcruntime140.dll"]])
        observation = self.observe(api)
        self.assertEqual(observation["processMachine"], ARM64)
        self.assertEqual(len(observation["modules"]), 5)
        self.assertEqual(api.closed, [("handle", 4242)])
        failures, images = RUN.assess_run(observation, "arm64", "C:\\Windows", native_image)
        self.assertEqual(failures, [])
        self.assertEqual([record["path"] for record in images],
                         [APP, "C:\\a\\swiftCore.dll", "C:\\a\\vcruntime140.dll"])

    def test_emulated_x64_process_on_an_arm64_host_fails(self):
        api = FakeAPI(machine=AMD64, modules=[[APP, "C:\\Windows\\System32\\xtajit64.dll"] + SYSTEM])
        failures, _ = RUN.assess_run(self.observe(api), "arm64", "C:\\Windows", native_image)
        self.assertIn("Windows reported a x64 process, not arm64", failures)
        self.assertTrue(any("emulation modules were loaded" in failure and "xtajit64.dll" in failure
                            for failure in failures))

    def test_foreign_modules_exit_codes_and_missing_evidence_fail(self):
        def reader(path, architecture):
            return {"path": path, "architecture": "x64" if "ggml" in path else "arm64", "native": "ggml" not in path}
        api = FakeAPI(modules=[[APP, "C:\\rt\\ggml-cpu.dll"] + SYSTEM])
        failures, _ = RUN.assess_run(self.observe(api, FakeProcess(exit_code=3)), "arm64", "C:\\Windows", reader)
        self.assertIn("exited with 3", failures)
        self.assertIn("loaded a x64 module: C:\\rt\\ggml-cpu.dll", failures)
        failures, _ = RUN.assess_run(self.observe(FakeAPI()), "arm64", "C:\\Windows", reader)
        self.assertIn("no loaded modules were observed", failures)

    def test_timeout_kills_the_process(self):
        process = FakeProcess(polls=1000)
        observation = self.observe(FakeAPI(modules=[[APP]]), process, timeout=3.0)
        self.assertTrue(process.killed)
        self.assertTrue(observation["timedOut"])
        failures, _ = RUN.assess_run(observation, "arm64", "C:\\Windows", native_image)
        self.assertIn("did not exit before its deadline", failures)

    def test_machine_is_only_inferred_without_process_machine_info_on_x64_hosts(self):
        x64 = FakeAPI(machine=None, native=AMD64, machine_error=True)
        self.assertEqual(HOST.query_machine(x64, "h"), (AMD64, None, AMD64))
        wow = FakeAPI(native=AMD64, wow64=PE.IMAGE_FILE_MACHINE_I386, machine_error=True)
        with self.assertRaises(OSError):
            HOST.query_machine(wow, "h")
        arm = FakeAPI(machine_error=True, modules=[[APP]])
        with self.assertRaises(OSError):
            HOST.query_machine(arm, "h")
        observation = self.observe(arm)
        self.assertIsNone(observation["processMachine"])
        self.assertTrue(observation["queryErrors"])
        failures, _ = RUN.assess_run(observation, "arm64", "C:\\Windows", native_image)
        self.assertIn("Windows reported a missing process, not arm64", failures)


class ApplicationErrorTests(unittest.TestCase):
    def setUp(self):
        self.started = datetime.datetime(2026, 10, 28, 7, 20, 0, tzinfo=datetime.timezone.utc)
        self.ended = self.started + datetime.timedelta(seconds=2)

    def event(self, **changes):
        data = {"AppName": "SpeakWindows.exe", "AppPath": APP, "ProcessId": "0x1092",
                "ModuleName": "ntdll.dll", "ModuleVersion": "10.0.26100.1",
                "ExceptionCode": "c0000374", "FaultingOffset": "0000000000012345"}
        data.update(changes)
        return {"time": "2026-10-28T07:20:01Z", "data": data}

    def project(self, events):
        return RUN.project_application_error(events, 4242, APP, self.started, self.ended)

    def query(self, payload, **changes):
        def child(arguments, **options):
            self.assertEqual(arguments[:5], ["pwsh", "-NoLogo", "-NoProfile", "-NonInteractive", "-Command"])
            self.assertIn("-MaxEvents 16", arguments[5])
            self.assertNotIn(".Message", arguments[5])
            self.assertNotIn("Execution", arguments[5])
            self.assertEqual(options["timeout"], 5)
            self.assertEqual(options["stdin"], subprocess.DEVNULL)
            self.assertEqual(options["stderr"], subprocess.DEVNULL)
            self.assertNotIn("EVENT_TEST_SECRET", options["env"])
            result = {"returncode": 0, "stdout": json.dumps(payload).encode()}
            result.update(changes)
            return types.SimpleNamespace(**result)
        with mock.patch.dict(os.environ, {"EVENT_TEST_SECRET": "private-canary"}):
            return RUN.application_error(4242, APP, self.started, self.ended, query=child)

    def test_exact_owned_crash_projects_only_finite_fields(self):
        result = self.query({"status": "ok", "events": [self.event()]})
        self.assertEqual(result, {"status": "observed", "module": "ntdll.dll", "version": "10.0.26100.1",
                                  "exceptionCode": "0xc0000374", "faultOffset": "0x0000000000012345",
                                  "timeUTC": "2026-10-28T07:20:01+00:00"})
        self.assertNotIn(APP, json.dumps(result))

    def test_wrong_process_path_application_and_time_do_not_match(self):
        for changes in ({"ProcessId": "4243"}, {"AppPath": r"C:\other\SpeakWindows.exe"},
                        {"AppName": "other.exe"}):
            with self.subTest(changes=changes):
                self.assertEqual(self.project([self.event(**changes)]), {"status": "no-match"})
        event = self.event()
        event["time"] = "2026-10-28T07:20:03Z"
        self.assertEqual(self.project([event]), {"status": "no-match"})

    def test_faulting_process_alias_is_explicit_and_conflict_is_unknown(self):
        event = self.event()
        del event["data"]["ProcessId"]
        event["data"]["FaultingProcessId"] = "4242"
        self.assertEqual(self.project([event])["status"], "observed")
        self.assertEqual(self.project([self.event(FaultingProcessId="4243")]), {"status": "invalid"})
        event = self.event()
        del event["data"]["ProcessId"]
        event["data"]["ExecutionProcessID"] = "4242"
        self.assertEqual(self.project([event]), {"status": "invalid"})

    def test_ambiguous_missing_and_oversized_sets_remain_unknown(self):
        self.assertEqual(self.project([]), {"status": "no-match"})
        self.assertEqual(self.project([self.event(), self.event()]), {"status": "ambiguous"})
        self.assertEqual(self.project([self.event()] * 17), {"status": "invalid"})

    def test_raw_messages_paths_and_invalid_numeric_values_cannot_escape(self):
        for changes in ({"ModuleName": r"C:\private-canary\ntdll.dll"}, {"ModuleVersion": "private-canary"},
                        {"ExceptionCode": "private-canary"}, {"FaultingOffset": "0x" + "f" * 17},
                        {"ProcessId": "0xprivate-canary"}, {"Message": "private-canary"}):
            with self.subTest(changes=changes):
                result = self.project([self.event(**changes)])
                self.assertEqual(result, {"status": "invalid"})
                self.assertNotIn("private-canary", json.dumps(result))
        for time in ("invalid", "2026-10-28T07:20:01", None):
            event = self.event()
            event["time"] = time
            self.assertEqual(self.project([event]), {"status": "invalid"})

    def test_query_failure_output_and_timeout_remain_fixed_unknown(self):
        for payload, options, expected in [({"status": "unavailable"}, {}, "unavailable"),
                                           ({"private-canary": "raw-response"}, {}, "invalid"),
                                           ({}, {"returncode": 1, "stdout": b"private-canary"}, "unavailable"),
                                           ({}, {"stdout": b"private-canary"}, "unavailable"),
                                           ({}, {"stdout": b"x" * 65537}, "invalid")]:
            with self.subTest(options=list(options), expected=expected):
                self.assertEqual(self.query(payload, **options), {"status": expected})
        for error, expected in [(subprocess.TimeoutExpired("private-canary", 5), "timeout"),
                                (PermissionError("private-canary"), "unavailable"),
                                (RuntimeError("private-canary"), "unavailable")]:
            with self.subTest(type=type(error).__name__):
                self.assertEqual(RUN.application_error(4242, APP, self.started, self.ended,
                                                         query=mock.Mock(side_effect=error)), {"status": expected})

    def test_run_queries_only_abnormal_owned_windows_smoke_without_changing_failures(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            executable = root / "SpeakWindows.exe"
            executable.write_bytes(FIXTURES.build_pe(machine=ARM64))
            stdout, stderr = root / "out", root / "err"
            reader = mock.Mock(return_value={"status": "observed", "module": "ntdll.dll"})
            windows = types.SimpleNamespace(name="nt", path=os.path, environ=os.environ)
            def launch(arguments, stdout, stderr):
                return FakeProcess(exit_code=3221226356)
            with mock.patch.object(RUN, "os", windows):
                result = RUN.run([str(executable), "--ui-smoke-test"], FakeAPI(modules=[[str(executable)]]),
                                    "arm64", "ui-smoke-test", 30, stdout, stderr, ["window passed"],
                                    "C:\\Windows", launch, native_image, reader)
            self.assertEqual(result["exitCode"], 3221226356)
            self.assertFalse(result["timedOut"])
            self.assertEqual(result["failures"], ["exited with 3221226356", "output lacks 'window passed'"])
            self.assertEqual(result["applicationError"]["module"], "ntdll.dll")
            self.assertEqual(reader.call_args.args[:2], (4242, os.path.abspath(executable)))
            self.assertLessEqual(reader.call_args.args[2], reader.call_args.args[3])
            reader.side_effect = RuntimeError("private-canary")
            with mock.patch.object(RUN, "os", windows):
                failed = RUN.run([str(executable), "--ui-smoke-test"], FakeAPI(modules=[[str(executable)]]),
                                    "arm64", "ui-smoke-test", 30, stdout, stderr, ["window passed"],
                                    "C:\\Windows", launch, native_image, reader)
            self.assertEqual(failed["failures"], result["failures"])
            self.assertEqual(failed["applicationError"], {"status": "unavailable"})

    def test_success_other_commands_nonwindows_and_intentional_timeout_never_query(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            executable = root / "SpeakWindows.exe"
            executable.write_bytes(FIXTURES.build_pe(machine=ARM64))
            for host, label, arguments, polls, code, timeout in [
                    ("nt", "ui-smoke-test", ["--ui-smoke-test"], 2, 0, 30),
                    ("nt", "self-test", ["--self-test"], 2, 1, 30),
                    ("nt", "ui-smoke-test", ["--self-test"], 2, 1, 30),
                    ("posix", "ui-smoke-test", ["--ui-smoke-test"], 2, 1, 30),
                    ("nt", "ui-smoke-test", ["--ui-smoke-test"], 100, 1, -1)]:
                with self.subTest(host=host, label=label, polls=polls):
                    reader = mock.Mock(side_effect=AssertionError("must not query"))
                    process = FakeProcess(polls=polls, exit_code=code)
                    environment = types.SimpleNamespace(name=host, path=os.path, environ=os.environ)
                    with mock.patch.object(RUN, "os", environment):
                        result = RUN.run([str(executable)] + arguments, FakeAPI(modules=[[str(executable)]]),
                                            "arm64", label, timeout, root / "out", root / "err", (),
                                            "C:\\Windows", lambda *a, **kw: process, native_image, reader)
                    reader.assert_not_called()
                    self.assertNotIn("applicationError", result)


class NativeOwnerRoutingTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="owned-routing-")
        self.addCleanup(self.directory.cleanup)
        self.root = pathlib.Path(self.directory.name)
        self.executable = self.root / "SpeakWindows.exe"
        self.executable.write_bytes(FIXTURES.build_pe(machine=ARM64))
        self.launches = []

    def operate(self, code=3221226356, polls=2, ticks=(1000, 11000), frequency=1000,
                context=True, deadline=31000, target_frequency=1000, launch_hook=None, **changes):
        samples, events = iter(ticks), []
        def next_tick():
            events.append("ticks")
            sample = next(samples)
            if isinstance(sample, Exception):
                raise sample
            return sample
        api_clock = types.SimpleNamespace(frequency=lambda: frequency, ticks=mock.Mock(side_effect=next_tick),
                                          events=events)
        process = FakeProcess(polls=polls, exit_code=code)
        event_reader = mock.Mock(side_effect=AssertionError("no optional process launch"))
        def launch(arguments, stdout, stderr):
            self.launches.append(arguments)
            events.append("launch")
            if launch_hook:
                launch_hook()
            return process
        launcher = mock.Mock(side_effect=launch)
        original_observe = RUN.observe
        observer = mock.Mock(side_effect=lambda process, api, timeout: original_observe(
            process, api, timeout=timeout, clock=Clock(step=0.25), sleep=lambda _: None))
        host = changes.pop("host", "nt")
        executable = changes.pop("executable", self.executable)
        argv = changes.pop("argv", ["--ui-smoke-test"])
        label = changes.pop("label", "ui-smoke-test")
        architecture = changes.pop("architecture", "arm64")
        timeout = changes.pop("timeout", 30)
        with mock.patch.object(RUN, "os", types.SimpleNamespace(name=host, path=os.path, environ=os.environ)), \
                mock.patch.object(RUN, "observe", observer), \
                mock.patch.object(subprocess, "run", side_effect=AssertionError("no PS/CDB")):
            result = RUN.run([str(executable)] + argv, FakeAPI(modules=[[str(executable)]]),
                                architecture, label, timeout, self.root / "out", self.root / "err", (),
                                "C:\\Windows", launcher, native_image, event_reader,
                                diagnostic_owner_context=context, deadline_ticks=deadline,
                                deadline_frequency=target_frequency, deadline_api_factory=lambda: api_clock,
                                **changes)
        return result, process, observer, api_clock, event_reader

    def test_actual_run_caps_after_popen_and_emits_closed_owned_context_without_launching_diagnostics(self):
        marker = []
        record, process, observer, clock, reader = self.operate(launch_hook=lambda: marker.append("launched"))
        self.assertEqual(marker, ["launched"])
        self.assertEqual(observer.call_args.kwargs["timeout"], 20)
        self.assertEqual(clock.ticks.call_count, 2)
        self.assertEqual(clock.events, ["ticks", "launch", "ticks"])
        self.assertEqual(len(self.launches), 1)
        self.assertEqual(record["exitCode"], 3221226356)
        self.assertEqual(record["failures"], ["exited with 3221226356"])
        context = record["diagnosticOwnerContext"]
        self.assertEqual(set(context), {"schema", "originalPid", "startedUTC", "endedUTC",
                                        "deadlineTicks", "frequency", "exitCode"})
        self.assertEqual((context["schema"], context["originalPid"], context["deadlineTicks"],
                          context["frequency"], context["exitCode"]), (1, process.pid, 31000, 1000, -1073740940))
        self.assertLessEqual(datetime.datetime.fromisoformat(context["startedUTC"]),
                             datetime.datetime.fromisoformat(context["endedUTC"]))
        self.assertNotIn(str(self.root), json.dumps(context))
        reader.assert_not_called()
        self.assertNotIn("applicationError", record)

    def test_known_signed_and_unsigned_crashes_preserve_original_exit_and_failure(self):
        for signed in RUN.CRASH_CODES:
            for code in (signed, signed + 0x100000000):
                with self.subTest(code=code):
                    record, _, _, _, _ = self.operate(code=code)
                    self.assertEqual(record["diagnosticOwnerContext"]["exitCode"], signed)
                    self.assertEqual(record["exitCode"], code)
                    self.assertEqual(record["failures"], ["exited with %s" % code])

    def test_unknown_success_and_noninteger_crash_codes_do_not_normalize(self):
        for code in (None, True, False, 0, 1, "3221226356", 3221226356.0, 3221226356 + 0x100000000,
                     -1073740940 - 0x100000000):
            with self.subTest(code=code):
                self.assertIsNone(RUN.normalize_native_crash(code))
        for code in (0, 1, 0xc000001d, 0x100000000 + 0xc0000374):
            record, _, _, _, reader = self.operate(code=code)
            self.assertNotIn("diagnosticOwnerContext", record)
            reader.assert_not_called()

    def test_exhausted_after_launch_kills_owned_process_and_preserves_timeout_without_context(self):
        result, process, observer, _, reader = self.operate(polls=1000, ticks=(1000, 32000))
        self.assertEqual(observer.call_args.kwargs["timeout"], 0)
        self.assertTrue(process.killed)
        self.assertTrue(result["timedOut"])
        self.assertIn("did not exit before its deadline", result["failures"])
        self.assertNotIn("diagnosticOwnerContext", result)
        reader.assert_not_called()

    def test_clock_error_after_launch_still_observes_and_reaps_owned_process(self):
        result, process, observer, _, _ = self.operate(polls=1000, ticks=(1000, OSError("private-canary")))
        self.assertEqual(observer.call_args.kwargs["timeout"], 0)
        self.assertTrue(process.killed)
        self.assertTrue(result["timedOut"])
        self.assertNotIn("private-canary", json.dumps(result))
        self.assertNotIn("diagnosticOwnerContext", result)

    def test_fast_natural_exit_after_qpc_error_retains_failure_without_optional_context(self):
        result, process, observer, _, reader = self.operate(polls=1, ticks=(1000, OSError("private-canary")))
        self.assertEqual(observer.call_args.kwargs["timeout"], 0)
        self.assertFalse(process.killed)
        self.assertFalse(result["timedOut"])
        self.assertEqual(result["failures"], ["exited with 3221226356"])
        self.assertNotIn("diagnosticOwnerContext", result)
        reader.assert_not_called()

    def test_qpc_remaining_cannot_extend_original_timeout(self):
        record, _, observer, _, _ = self.operate(timeout=7, ticks=(1000, 2000))
        self.assertEqual(observer.call_args.kwargs["timeout"], 7)
        self.assertEqual(record["diagnosticOwnerContext"]["deadlineTicks"], 31000)

    def test_invalid_qpc_frequency_bounds_and_missing_fields_refuse_before_launch(self):
        invalid = [dict(deadline=None), dict(deadline=True), dict(deadline=0), dict(deadline=1 << 63),
                   dict(target_frequency=None), dict(target_frequency=0), dict(target_frequency=True),
                   dict(target_frequency=1 << 63), dict(frequency=2000), dict(ticks=(1000,), deadline=32001),
                   dict(ticks=(31000,)), dict(ticks=(32000,))]
        for changes in invalid:
            with self.subTest(changes=changes), \
                    mock.patch.object(RUN, "observe", side_effect=AssertionError("no child observation")), \
                    mock.patch.object(subprocess, "Popen", side_effect=AssertionError("no launch")):
                # Factory admission happens before the fixture's launcher; output files aren't opened.
                with self.assertRaises(HOST.ExecutionError):
                    self.operate(**changes)
                self.assertFalse((self.root / "out").exists())
                self.assertEqual(self.launches, [])

    def test_optin_wrong_host_target_label_program_arguments_or_timeout_refuses_before_launch(self):
        other = self.root / "Other.exe"
        other.write_bytes(FIXTURES.build_pe(machine=ARM64))
        x64 = self.root / "x64" / "SpeakWindows.exe"
        x64.parent.mkdir()
        x64.write_bytes(FIXTURES.build_pe(machine=AMD64))
        for changes in [dict(host="posix"), dict(architecture="x64", executable=x64),
                        dict(label="self-test"), dict(executable=other), dict(argv=["--self-test"]),
                        dict(argv=["--ui-smoke-test", "private-canary"]), dict(timeout=31),
                        dict(timeout=0), dict(timeout=float("nan"))]:
            with self.subTest(changes=changes), self.assertRaises(HOST.ExecutionError):
                self.operate(**changes)
            self.assertFalse((self.root / "out").exists())
            self.assertEqual(self.launches, [])

    def test_deadline_without_optin_refuses_but_no_flags_preserve_legacy_arm_behavior(self):
        with self.assertRaises(HOST.ExecutionError):
            self.operate(context=False)
        record, _, observer, clock, _ = self.operate(context=False, deadline=None, target_frequency=None,
                                                   host="posix", code=0)
        self.assertEqual(observer.call_args.kwargs["timeout"], 30)
        clock.ticks.assert_not_called()
        self.assertEqual(record["failures"], [])
        self.assertNotIn("diagnosticOwnerContext", record)

    def test_context_refuses_wrong_machine_bad_pid_timeout_or_invalid_utc_interval(self):
        start = datetime.datetime(2026, 10, 28, tzinfo=datetime.timezone.utc)
        observation = {"exitCode": 0xc0000374, "timedOut": False, "processMachine": ARM64, "nativeMachine": ARM64}
        deadline = types.SimpleNamespace(end=31000, frequency=1000)
        for pid, changes, seconds in [(True, {}, 1), (0, {}, 1), (1 << 32, {}, 1),
                                     (1, {"processMachine": AMD64}, 1), (1, {"nativeMachine": AMD64}, 1),
                                     (1, {"timedOut": True}, 1), (1, {}, -1), (1, {}, 30.001)]:
            with self.subTest(pid=pid, changes=changes, seconds=seconds):
                self.assertIsNone(RUN.native_owner_context(types.SimpleNamespace(pid=pid),
                    {**observation, **changes}, start, start + datetime.timedelta(seconds=seconds), deadline))

    def test_actual_python_owned_record_roundtrips_through_shared_powershell_native_adapter(self):
        host = shutil.which("pwsh")
        if host is None:
            self.skipTest("PowerShell unavailable: actual native context boundary not executed")
        with tempfile.TemporaryDirectory() as directory:
            environment = {key: value for key, value in os.environ.items()
                           if key.upper() in {"PATH", "SYSTEMROOT", "WINDIR", "HOME"}}
            environment.update(TEMP=directory, TMP=directory, TMPDIR=directory,
                               JSTI_PROJECTOR=str(HERE / "FailureDiagnostics.ps1"))
            query = subprocess.run([os.path.abspath(host), "-NoLogo", "-NoProfile", "-NonInteractive", "-Command",
                                    "@{frequency=[System.Diagnostics.Stopwatch]::Frequency;ticks=[System.Diagnostics.Stopwatch]::GetTimestamp()} | ConvertTo-Json -Compress"],
                                   env=environment, cwd=directory, capture_output=True,
                                   timeout=10, check=False)
            self.assertEqual(query.returncode, 0)
            self.assertEqual(query.stderr, b"")
            clock = json.loads(query.stdout)
            frequency, ticks = clock["frequency"], clock["ticks"]
            self.assertTrue(0 < frequency <= 1000000000)
            self.assertTrue(ticks > 0)
            image = {"path": APP, "name": "SpeakWindows.exe", "architecture": "arm64", "native": True,
                     "dll": False, "sha256": "a" * 64}
            with mock.patch.object(RUN, "check_images", return_value=[image]):
                record, _, _, _, _ = self.operate(executable=APP, frequency=frequency,
                    target_frequency=frequency, deadline=ticks + 30 * frequency, ticks=(ticks, ticks + 10 * frequency))
            script = r"""
$ErrorActionPreference='Stop'
. $env:JSTI_PROJECTOR
$document=[System.Text.Json.JsonDocument]::Parse([Console]::In.ReadToEnd())
$run=ConvertFrom-JstiEvidenceElement $document.RootElement
$original=(Get-Item Function:Invoke-JstiStandaloneDiagnostic).ScriptBlock
try {
    Set-Item Function:Invoke-JstiStandaloneDiagnostic {
        param($Setup,$Run,$Process,$Executable,$ExpectedSHA256,$DeadlineTicks,$Frequency,$StartedUTC,$EndedUTC)
        $script:handoff=@{adapted=$Run;pid=$Process.Id;deadline=$DeadlineTicks;frequency=$Frequency;
            executable=$Executable;hash=$ExpectedSHA256;start=$StartedUTC.ToString('o');end=$EndedUTC.ToString('o')}
        return @{status='unavailable'}
    }
    $result=Invoke-JstiNativeFailureDiagnostic @{Host=@{};Python=@{}} $run $run.executable.path `
        $run.executable.sha256 $run.diagnosticOwnerContext.deadlineTicks $run.diagnosticOwnerContext.frequency
    @{result=$result;handoff=$script:handoff;originalExit=$run.exitCode;failures=$run.failures} |
        ConvertTo-Json -Depth 12 -Compress
} finally {
    Set-Item Function:Invoke-JstiStandaloneDiagnostic $original
    $document.Dispose()
}
"""
            completed = subprocess.run([os.path.abspath(host), "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", script],
                                       input=json.dumps(record).encode(), env=environment, cwd=directory,
                                       capture_output=True, timeout=15, check=False)
        self.assertEqual(completed.returncode, 0, "actual shared native adapter failed")
        self.assertEqual(completed.stderr, b"")
        self.assertLessEqual(len(completed.stdout), 8192)
        actual = json.loads(completed.stdout)
        self.assertEqual(actual["result"], {"status": "unavailable"})
        self.assertEqual(actual["originalExit"], record["exitCode"])
        self.assertEqual(actual["failures"], record["failures"])
        handoff = actual["handoff"]
        self.assertEqual(handoff["adapted"], {"label": "ui-smoke", "arguments": "--ui-smoke-test",
                                              "exitCode": -1073740940, "processMachine": "0xAA64"})
        self.assertEqual((handoff["pid"], handoff["deadline"], handoff["frequency"]),
                         (4242, ticks + 30 * frequency, frequency))
        self.assertEqual((handoff["executable"], handoff["hash"]), (APP, "a" * 64))
        for key, context_key in (("start", "startedUTC"), ("end", "endedUTC")):
            self.assertEqual(datetime.datetime.fromisoformat(handoff[key]),
                             datetime.datetime.fromisoformat(record["diagnosticOwnerContext"][context_key]))

    def test_actual_cli_forwards_owned_deadline_and_persists_original_failed_record(self):
        stdout, stderr, evidence = self.root / "out", self.root / "err", self.root / "evidence.json"
        stdout.write_text("owned smoke output", encoding="utf-8")
        stderr.write_text("", encoding="utf-8")
        record = {"label": "ui-smoke-test", "processMachine": "arm64", "exitCode": 3221226356,
                  "modulesObserved": 1, "seconds": 1, "failures": ["exited with 3221226356"],
                  "diagnosticOwnerContext": {"schema": 1, "originalPid": 4242}}
        windows = types.SimpleNamespace(name="nt", path=os.path, environ=os.environ, replace=os.replace)
        with mock.patch.object(NATIVE, "os", windows), mock.patch.object(NATIVE, "WindowsAPI", return_value=FakeAPI()), \
                mock.patch.object(NATIVE, "run", return_value=record) as invoke, contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaisesRegex(HOST.ExecutionError, "exited with 3221226356"):
                NATIVE.main(["--architecture", "arm64", "--evidence", str(evidence), "run",
                    "--label", "ui-smoke-test", "--timeout", "30", "--stdout", str(stdout), "--stderr", str(stderr),
                    "--diagnostic-owner-context", "--deadline-ticks", "31000", "--deadline-frequency", "1000",
                    "--", str(self.executable), "--ui-smoke-test"])
        self.assertEqual(invoke.call_args.kwargs, {"diagnostic_owner_context": True,
                                                   "deadline_ticks": 31000, "deadline_frequency": 1000})
        self.assertEqual(invoke.call_args.args[0], [str(self.executable), "--ui-smoke-test"])
        self.assertEqual(json.loads(evidence.read_text(encoding="utf-8"))["runs"], [record])

    def test_parser_carries_exact_context_options_without_consuming_program_arguments(self):
        args = NATIVE.parse_arguments(["--architecture", "arm64", "--evidence", "owned.json", "run",
            "--label", "ui-smoke-test", "--timeout", "30", "--stdout", "out", "--stderr", "err",
            "--diagnostic-owner-context", "--deadline-ticks", "31000", "--deadline-frequency", "1000",
            "--", "SpeakWindows.exe", "--ui-smoke-test"])
        self.assertTrue(args.diagnostic_owner_context)
        self.assertEqual((args.deadline_ticks, args.deadline_frequency), (31000, 1000))
        self.assertEqual(args.arguments, ["SpeakWindows.exe", "--ui-smoke-test"])


class CommandLineTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = pathlib.Path(self.directory.name)
        self.evidence = self.root / "evidence.json"

    def test_image_evidence_accumulates_and_keeps_its_architecture(self):
        first, second = self.root / "a.exe", self.root / "b.dll"
        first.write_bytes(FIXTURES.build_pe(machine=ARM64))
        second.write_bytes(FIXTURES.build_pe(machine=ARM64, dll=True))
        with contextlib.redirect_stdout(io.StringIO()) as output:
            NATIVE.main(["--architecture", "arm64", "--evidence", str(self.evidence), "images", str(first)])
            NATIVE.main(["--architecture", "arm64", "--evidence", str(self.evidence), "images", str(second)])
        self.assertEqual(output.getvalue().splitlines(), ["1 native arm64 images"] * 2)
        evidence = json.loads(self.evidence.read_text(encoding="utf-8"))
        self.assertEqual([record["name"] for record in evidence["images"]], ["a.exe", "b.dll"])
        with self.assertRaisesRegex(HOST.ExecutionError, "records arm64, not x64"):
            NATIVE.main(["--architecture", "x64", "--evidence", str(self.evidence), "images", str(first)])

    def test_failures_still_write_evidence(self):
        foreign = self.root / "x64.exe"
        foreign.write_bytes(FIXTURES.build_pe())
        with self.assertRaises(HOST.ExecutionError):
            NATIVE.main(["--architecture", "arm64", "--evidence", str(self.evidence), "images", str(foreign)])
        self.assertEqual(json.loads(self.evidence.read_text(encoding="utf-8"))["images"], [])

    def test_program_arguments_after_the_separator_are_passed_unchanged(self):
        args = NATIVE.parse_arguments([
            "--architecture", "arm64", "--evidence", "e.json", "run", "--label", "local", "--timeout", "480",
            "--stdout", "o.log", "--stderr", "e.log", "--expect-output", "Local transcription self-test passed", "--",
            "C:\\app\\SpeakWindows.exe", "--local-transcription-self-test", "C:\\a b\\jfk.wav", "--expect",
            "ask not what your country can do for you"])
        self.assertEqual(args.arguments, ["C:\\app\\SpeakWindows.exe", "--local-transcription-self-test",
                                          "C:\\a b\\jfk.wav", "--expect", "ask not what your country can do for you"])
        self.assertEqual(args.expect_output, ["Local transcription self-test passed"])
        self.assertEqual(args.timeout, 480.0)
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
            NATIVE.parse_arguments(["--architecture", "arm64", "--evidence", "e.json", "run", "--label", "x",
                                    "--timeout", "1", "--stdout", "o", "--stderr", "e", "--"])

    @unittest.skipIf(os.name == "nt", "the refusal applies to hosts without the Windows process API")
    def test_process_checks_refuse_to_run_off_windows(self):
        with self.assertRaisesRegex(HOST.ExecutionError, "runs on Windows only"):
            NATIVE.main(["--architecture", "arm64", "--evidence", str(self.evidence), "host"])


if __name__ == "__main__":
    unittest.main()
