#!/usr/bin/env python3
"""The standalone CDB diagnostic and its PowerShell bootstrap (native_execution_debugger).

Unit tests for verify-native-execution.py; Windows process calls are faked.
"""
import base64
import contextlib
import hashlib
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
import native_execution_host as HOST  # noqa: E402
import native_execution_process as PROCESS  # noqa: E402
from native_execution_fakes import (  # noqa: E402
    AMD64,
    ARM64,
    FIXTURES,
    NATIVE,
    Clock,
    StandaloneRequests,
)


class StandaloneDiagnosticTests(StandaloneRequests, unittest.TestCase):
    def test_closed_request_refuses_unowned_or_arbitrary_operation_before_any_effect(self):
        mutations = [dict(extra="private-canary"), dict(schema=True), dict(originalPid=True), dict(parentPid=0),
                     dict(label="ui-smoke-test"), dict(arguments=["--help"]), dict(exitCode=0), dict(architecture="x64"),
                     dict(executable=r"\\server\SpeakWindows.exe"), dict(executable=r"C:\a\..\SpeakWindows.exe"),
                     dict(executable=r"C:\a\SpeakWindows.exe:stream"), dict(powershell=r"C:\a\cmd.exe"),
                     dict(expectedSHA256="X" * 64), dict(powershellSHA256="wrong"),
                     dict(startedUTC="2026-10-28T12:00:00"), dict(endedUTC="2026-10-28T12:00:31Z")]
        for changes in mutations:
            with self.subTest(changes=tuple(changes)):
                with self.assertRaises(ValueError):
                    DEBUGGER.diagnostic_request(self.encode(self.request(**changes)))
        for encoded in ("", "a" * 10925, "e30=", self.encode({"private-canary": "never"}),
                        base64.urlsafe_b64encode(b'{"schema":1,"schema":1}').decode().rstrip("=")):
            with self.assertRaises((ValueError, UnicodeError)):
                DEBUGGER.diagnostic_request(encoded)
        identity, runner = mock.Mock(), mock.Mock()
        result = self.operate(api=self.api(admitted=lambda _: False), identity=identity, runner=runner)
        self.assertEqual(result["status"], "invalid")
        identity.assert_not_called()
        runner.assert_not_called()

    def test_qpc_frequency_deadline_and_cleanup_reserve_refuse_before_launch(self):
        for api in (self.api(frequency=lambda: 999), self.api(ticks=lambda: 30000), self.api(ticks=lambda: -1)):
            with self.assertRaises(ValueError):
                PROCESS.DiagnosticBudget(self.request(), api)
        calls = []
        result = self.operate(api=self.api(ticks=lambda: 26000), runner=lambda *a, **k: calls.append(a))
        self.assertEqual(result["status"], "deadline")
        self.assertEqual(calls, [])

    def test_child_job_checks_only_defend_trusted_parent_and_exact_kill_flags(self):
        import ctypes
        for member, flags, parent, query_ok in ((1, 0x2000, 123, True), (0, 0x2000, 123, True),
                                                (1, 0x2800, 123, True), (1, 0x3000, 123, True),
                                                (1, 0x2000, 124, True), (1, 0x2000, 123, False)):
            def in_job(process, job, result):
                self.assertIsNone(job)
                result._obj.value = member
                return 1
            def info(job, kind, limits, size, returned):
                self.assertIsNone(job)
                self.assertEqual(kind, 9)
                limits._obj.basic.flags = flags
                returned._obj.value = size
                return int(query_ok)
            api = PROCESS.StandaloneWindows.__new__(PROCESS.StandaloneWindows)
            api.ctypes = ctypes
            api.api = types.SimpleNamespace(GetCurrentProcess=lambda: -1, IsProcessInJob=in_job,
                                            QueryInformationJobObject=info)
            with mock.patch.object(os, "getppid", return_value=parent):
                self.assertEqual(bool(api.admitted(self.request())), member == 1 and flags == 0x2000 and
                                 parent == 123 and query_ok)

    def test_parser_emits_only_unique_module_rvas_not_raw_paths_symbols_or_addresses(self):
        expected = {"status": "observed", "exceptionCode": "0xc0000374", "frames": [
            {"index": 0, "module": "app", "rva": "0x42"}, {"index": 1, "module": "unknown", "rva": "0x24"}]}
        self.assertEqual(DEBUGGER.project_debugger(self.fixture()), expected)
        self.assertEqual(DEBUGGER.project_debugger(self.fixture().replace(b"private-canary", "ιδιωτικό".encode())), expected)
        serialized = json.dumps(expected)
        for private in ("private", "function", "00000001", "00000002", "C:\\", "bad", "feed"):
            self.assertNotIn(private, serialized)
        for suffix in (b"", b"arbitrary target output\n"):
            self.assertEqual(DEBUGGER.project_debugger(b"JSTI_DIAG_READY\n" + suffix)["status"], "no-reproduction")
        self.assertEqual(DEBUGGER.project_debugger(b"JSTI_DIAG_READY\n", False)["status"], "unavailable")

    def test_parser_refuses_ambiguous_missing_malformed_spoofed_and_oversized_frames(self):
        original = self.fixture()
        variants = [original.replace(b"JSTI_DIAG_READY\n", b""), original + b"JSTI_DIAG_READY\n",
                    original.replace(b"JSTI_DIAG_END", b""), original.replace(b"c0000374", b"deadbeef"),
                    original.replace(b"JSTI_DIAG_STACK", b"JSTI_DIAG_MODULES"),
                    original.replace(b"00 00000003", b"05 00000003"),
                    original.replace(b"JSTI_DIAG_IP 00000001`00000042", b"JSTI_DIAG_IP 00000009`00000042"),
                    original.replace(b"JSTI_DIAG_STACK", b"00000001`00000000 00000001`00001000 ntdll\nJSTI_DIAG_STACK")]
        for data in variants:
            self.assertEqual(DEBUGGER.project_debugger(data)["status"], "invalid")
        for data in (b"x" * 65537, b"x" * 2049 + b"\n"):
            self.assertEqual(DEBUGGER.project_debugger(data)["status"], "truncated")

    def test_actual_python_projection_roundtrips_through_actual_powershell_closed_projector(self):
        host = shutil.which("pwsh")
        if host is None:
            self.skipTest("PowerShell unavailable: actual cross-language projection not executed")
        value = DEBUGGER.diagnostic_result("observed", "clean")
        value["debugger"] = DEBUGGER.project_debugger(self.fixture())
        # Definitions-only shared helper has no verifier or native preparation;
        # only its pure closed JSON projection is called.
        script = """
$ErrorActionPreference='Stop'
. $env:JSTI_PROJECTOR
$value=[Console]::In.ReadToEnd() | ConvertFrom-Json -Depth 8
ConvertTo-JstiDiagnosticProjection $value | ConvertTo-Json -Depth 8 -Compress
"""
        with tempfile.TemporaryDirectory() as directory:
            environment = {key: val for key, val in os.environ.items()
                           if key.upper() in {"PATH", "SYSTEMROOT", "WINDIR", "HOME"}}
            environment.update(TEMP=directory, TMP=directory, TMPDIR=directory,
                               JSTI_PROJECTOR=str(HERE / "FailureDiagnostics.ps1"))
            completed = subprocess.run([os.path.abspath(host), "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", script],
                                       input=json.dumps(value).encode(), env=environment, cwd=directory,
                                       capture_output=True, timeout=15, check=False)
        self.assertEqual(completed.returncode, 0, "actual pure projector failed")
        self.assertEqual(completed.stderr, b"")
        self.assertLessEqual(len(completed.stdout), 8192)
        self.assertEqual(json.loads(completed.stdout), value)

    def test_actual_operation_keeps_fixed_argv_private_environment_once_and_owned_temp(self):
        calls, snapshots = [], []
        def identity(path, digest, maximum, budget, **kwargs):
            snapshots.append((path, digest, kwargs))
            return path, digest
        def runner(argv, environment, directory, budget, seconds, **kwargs):
            calls.append(argv)
            self.assertNotIn("OP_SERVICE_ACCOUNT_TOKEN", environment)
            self.assertNotIn("_NT_SYMBOL_PATH", environment)
            self.assertNotIn("ICU_DATA", environment)
            self.assertEqual(environment["TEMP"], directory)
            self.assertEqual(environment["USERPROFILE"], directory)
            self.assertTrue(pathlib.Path(directory).is_dir())
            if argv[0] != DEBUGGER.CDB_LOCATION:
                self.assertEqual(argv[:4], [self.request()["powershell"], "-NoLogo", "-NoProfile", "-NonInteractive"])
                return dict(status="complete", cleanup="clean", output=b'{"status":"unavailable"}', exitCode=0)
            self.assertLessEqual(seconds, 20)
            self.assertEqual(argv[1:7], ["-hd", "-G", "-sins", "-noshell", "-nosqm", "-netsyms:no"])
            self.assertEqual(argv[-2:], [self.request()["executable"], "--ui-smoke-test"])
            self.assertNotIn("-pd", argv)
            script = pathlib.Path(argv[argv.index("-cf") + 1])
            self.assertEqual(script.read_text(encoding="utf-8"), DEBUGGER.cdb_commands())
            self.assertEqual(list(pathlib.Path(argv[argv.index("-y") + 1]).iterdir()), [])
            self.assertEqual(script.parent, pathlib.Path(directory))
            return dict(status="complete", cleanup="clean", output=self.fixture(), exitCode=0)
        with mock.patch.dict(os.environ, {"OP_SERVICE_ACCOUNT_TOKEN": "private-canary", "_NT_SYMBOL_PATH": "https://private", "ICU_DATA": "private"}):
            result = self.operate(identity=identity, runner=runner)
        self.assertEqual(result["status"], "observed")
        self.assertEqual(result["cleanup"], "clean")
        self.assertEqual(len(calls), 2)
        self.assertEqual([item[0] for item in snapshots], [self.request()["executable"], self.request()["powershell"],
                                                        DEBUGGER.CDB_LOCATION, self.request()["executable"], self.request()["powershell"]])
        self.assertEqual(snapshots[2][1], DEBUGGER.CDB_SHA256)
        self.assertEqual(snapshots[2][2], {"version": [10, 0, 26100, 6584]})
        self.assertNotIn("private", json.dumps(result))
        self.assertNotIn("JSTI_DIAG", json.dumps(result))

    def test_event1000_uses_absolute_host_and_original_owned_identity_then_reprojects(self):
        value = self.request()
        event = {"time": "2026-10-28T12:00:02Z", "data": {"AppName": "SpeakWindows.exe", "AppPath": value["executable"],
                 "ProcessId": "321", "ModuleName": "private_module.dll", "ModuleVersion": "1.2.3.4",
                 "ExceptionCode": "c0000374", "FaultingOffset": "0x123"}}
        def runner(argv, environment, *args, **kwargs):
            if argv[0] == value["powershell"]:
                self.assertEqual(environment["JSTI_EVENT_START"], value["startedUTC"])
                self.assertEqual(environment["JSTI_EVENT_END"], value["endedUTC"])
                return dict(status="complete", cleanup="clean", exitCode=0,
                            output=json.dumps({"status": "ok", "events": [event]}).encode())
            return dict(status="complete", cleanup="clean", exitCode=0, output=b"JSTI_DIAG_READY\n")
        result = self.operate(runner=runner)
        self.assertEqual(result["applicationError"], {"status": "observed", "module": "unknown", "version": "1.2.3.4",
                                                     "exceptionCode": "0xc0000374", "faultOffset": "0x0000000000000123"})
        self.assertEqual(result["status"], "observed")
        self.assertNotIn("timeUTC", json.dumps(result))
        self.assertNotIn("private_module", json.dumps(result))
        event["data"]["ProcessId"] = "999"
        self.assertEqual(self.operate(runner=runner)["applicationError"], {"status": "no-match"})

    def test_identity_or_reader_cleanup_failure_never_launches_or_reports_observed(self):
        for location in (self.request()["executable"], self.request()["powershell"], DEBUGGER.CDB_LOCATION):
            launches = []
            def identity(path, *args, **kwargs):
                if path == location:
                    raise PermissionError("private-canary")
                return path, "same"
            def runner(*args, **kwargs):
                launches.append(args[0][0])
                return dict(status="complete", cleanup="clean", output=b'{"status":"unavailable"}', exitCode=0)
            result = self.operate(identity=identity, runner=runner)
            self.assertEqual(result["status"], "unavailable")
            self.assertEqual(result["cleanup"], "clean" if location == DEBUGGER.CDB_LOCATION else "not-started")
            self.assertNotIn(DEBUGGER.CDB_LOCATION, launches)
            self.assertNotIn("private", json.dumps(result))
        result = self.operate(runner=lambda *a, **k: dict(status="complete", cleanup="failed", output=self.fixture(), exitCode=0))
        self.assertEqual(result["cleanup"], "failed")
        self.assertNotEqual(result["status"], "observed")

    def test_event_work_consumes_same_deadline_and_image_replacement_refuses_cdb(self):
        now, calls = [10000], []
        def query(argv, *args, **kwargs):
            calls.append(argv[0])
            now[0] = 26000
            return dict(status="complete", cleanup="clean", output=b'{"status":"unavailable"}', exitCode=0)
        result = self.operate(api=self.api(ticks=lambda: now[0]), runner=query)
        self.assertEqual(result["status"], "deadline")
        self.assertEqual(calls, [self.request()["powershell"]])
        copies, calls = {}, []
        def identity(path, *args, **kwargs):
            copies[path] = copies.get(path, 0) + 1
            return path, copies[path]
        result = self.operate(identity=identity, runner=lambda argv, *a, **k: calls.append(argv[0]) or
                              dict(status="complete", cleanup="clean", output=b'{"status":"unavailable"}', exitCode=0))
        self.assertEqual(result["status"], "unavailable")
        self.assertEqual(calls, [self.request()["powershell"]])

    def test_collector_faults_and_truncation_are_finite_and_cannot_become_observed(self):
        for status in ("deadline", "truncated", "unavailable", "private-canary"):
            def runner(argv, *args, **kwargs):
                return dict(status=status if argv[0] == DEBUGGER.CDB_LOCATION else "complete", cleanup="clean",
                            output=b'{"status":"unavailable"}', exitCode=0)
            result = self.operate(runner=runner)
            self.assertEqual(result["status"], status if status in DEBUGGER.STANDALONE_STATUSES else "unavailable")
            self.assertNotIn("private", json.dumps(result))
        result = self.operate(runner=lambda *a, **k: (_ for _ in ()).throw(OSError("private-canary")))
        self.assertEqual(result["status"], "unavailable")
        self.assertNotIn("private", json.dumps(result))
        with tempfile.TemporaryDirectory() as directory:
            class FailedScratchCleanup:
                name = directory
                def __enter__(self):
                    return self.name
                def __exit__(self, *args):
                    raise OSError("private-canary")
            with mock.patch.object(tempfile, "TemporaryDirectory", return_value=FailedScratchCleanup()):
                result = self.operate()
            self.assertEqual(result["status"], "unavailable")
            self.assertEqual(result["cleanup"], "failed")
            self.assertNotIn("private", json.dumps(result))

    def test_refusal_facts_keep_original_parser_outcomes_for_each_reachable_guard(self):
        original = self.fixture()
        cases = [
            (original.replace(b"JSTI_DIAG_READY\n", b""), "ready-marker-count"),
            (original.replace(b"JSTI_DIAG_END", b""), "fault-boundary"),
            (original.replace(b"c0000374", b"deadbeef"), "fault-code-order"),
            (original.replace(b"JSTI_DIAG_STACK", b"JSTI_DIAG_MODULES"), "section-boundary"),
            (original.replace(b"JSTI_DIAG_IP 00000001`00000042\n", b""), "ip-count"),
            (original.replace(b"00000001`00001000 SpeakWindows", b"00000001`00000000 SpeakWindows"), "module-range"),
            (original.replace(b"00 00000003", b"05 00000003"), "stack-row-order"),
            (b"\n".join(line for line in original.split(b"\n") if not line.startswith((b"00 ", b"01 "))), "stack-row-count"),
            (original.replace(b"JSTI_DIAG_IP 00000001`00000042", b"JSTI_DIAG_IP 00000009`00000042"), "frame-range"),
        ]
        for data, reason in cases:
            with self.subTest(reason=reason):
                projected = DEBUGGER.project_debugger(data, completion_class="nonzero")
                facts = projected.pop("refusalFacts")
                self.assertEqual(projected, {"status": "invalid", "exceptionCode": None, "frames": []})
                self.assertEqual(facts["reason"], reason)
                self.assertEqual(facts["completionClass"], "nonzero")
                self.assertEqual(set(facts["counts"]), {"ready", "fault", "end", "modules", "stack", "ip", "moduleRanges", "stackRows"})
                self.assertTrue(all(type(count) is int and 0 <= count <= 17 for count in facts["counts"].values()))
        for data in (original, b"JSTI_DIAG_READY\n", b"x" * 65537, b"x" * 2049):
            self.assertNotIn("refusalFacts", DEBUGGER.project_debugger(data))

    def test_refusal_facts_saturate_counts_without_canaries_utf8_or_raw_fragments(self):
        data = b"JSTI_DIAG_READY\n" * 40 + b"JSTI_DIAG_FAULT 0xc0000374\n" * 35
        data += b"JSTI_DIAG_END\n" * 20 + b"JSTI_DIAG_MODULES\n" * 30 + b"JSTI_DIAG_STACK\n" * 18
        data += b"C:\\PRIVATE_CANARY !private_function 00000001`00000042 \xff " + "ιδιωτικό".encode()
        facts = DEBUGGER.project_debugger(data)["refusalFacts"]
        self.assertEqual(facts["counts"], dict(ready=17, fault=17, end=17, modules=17, stack=17,
                                              ip=0, moduleRanges=0, stackRows=0))
        serialized = json.dumps(facts)
        for private in ("PRIVATE", "private_function", "00000001", "ιδιωτικό", "C:\\", "JSTI_DIAG"):
            self.assertNotIn(private, serialized)
        for value in (True, 0, None, "ZERO", "zero\n", "PRIVATE_CANARY"):
            with self.assertRaises(ValueError):
                DEBUGGER.project_debugger(data, completion_class=value)

    def test_actual_operation_attaches_completion_class_and_retires_late_refusal_facts(self):
        for code, expected in ((0, "zero"), (42, "nonzero"), (None, "unknown"), (True, "unknown")):
            def runner(argv, *args, **kwargs):
                return dict(status="complete", cleanup="clean", exitCode=code if argv[0] == DEBUGGER.CDB_LOCATION else 0,
                            output=b"PRIVATE_CANARY" if argv[0] == DEBUGGER.CDB_LOCATION else b'{"status":"unavailable"}')
            result = self.operate(runner=runner)
            self.assertEqual(result["debugger"]["refusalFacts"]["completionClass"], expected)
            self.assertNotIn("PRIVATE", json.dumps(result))
        for mode in ("cutoff", "scratch", "child-cleanup", "clock"):
            now = [10000]
            def ticks():
                if now[0] is None:
                    raise OSError("PRIVATE_CANARY")
                return now[0]
            with tempfile.TemporaryDirectory() as directory:
                class LateScratch:
                    name = directory
                    def __enter__(self):
                        return self.name
                    def __exit__(self, *args):
                        if mode == "scratch":
                            raise OSError("PRIVATE_CANARY")
                        now[0] = None if mode == "clock" else 28000
                def runner(argv, *args, **kwargs):
                    return dict(status="complete", cleanup="failed" if mode == "child-cleanup" else "clean",
                                exitCode=0, output=b"PRIVATE_CANARY" if argv[0] == DEBUGGER.CDB_LOCATION
                                else b'{"status":"unavailable"}')
                with mock.patch.object(tempfile, "TemporaryDirectory", return_value=LateScratch()):
                    result = self.operate(api=self.api(ticks=ticks), runner=runner)
                self.assertNotIn("refusalFacts", result["debugger"])
                self.assertNotIn("PRIVATE", json.dumps(result))

    def test_actual_refusal_facts_python_to_powershell_boundary_rejects_malicious_shapes(self):
        host = shutil.which("pwsh")
        if host is None:
            self.skipTest("PowerShell unavailable: actual refusal-facts boundary not executed")
        value = DEBUGGER.diagnostic_result("invalid", "clean")
        value["debugger"] = DEBUGGER.project_debugger(b"PRIVATE_CANARY\xff", completion_class="nonzero")
        values = [value]
        def changed(change):
            clone = json.loads(json.dumps(value))
            change(clone)
            values.append(clone)
        for key, item in (("reason", "PRIVATE_CANARY"), ("reason", "READY-MARKER-COUNT"),
                          ("completionClass", "zero\n"), ("completionClass", True), ("extra", "PRIVATE_CANARY")):
            changed(lambda clone, key=key, item=item: clone["debugger"]["refusalFacts"].update({key: item}))
        for count in (True, False, -1, 18, 1.5, "1", "PRIVATE_CANARY", "x" * 9000):
            changed(lambda clone, count=count: clone["debugger"]["refusalFacts"]["counts"].update(ready=count))
        for field in ("reason", "completionClass", "counts"):
            changed(lambda clone, field=field: clone["debugger"]["refusalFacts"].pop(field))
        changed(lambda clone: clone["debugger"]["refusalFacts"]["counts"].pop("ready"))
        changed(lambda clone: clone["debugger"]["refusalFacts"]["counts"].update(extra=0))
        changed(lambda clone: clone["debugger"]["refusalFacts"].update(Counts={}))
        changed(lambda clone: clone["debugger"].update(status="observed"))
        changed(lambda clone: clone.update(cleanup="failed"))
        changed(lambda clone: clone.update(status="observed"))
        changed(lambda clone: clone["debugger"].update(refusalFacts=None))
        changed(lambda clone: clone["debugger"].update(exceptionCode="0xc0000374"))
        changed(lambda clone: clone["debugger"].update(frames=[dict(index=0, module="app", rva="0x1")]))
        script = """
$ErrorActionPreference='Stop'
. $env:JSTI_PROJECTOR
$values=[Console]::In.ReadToEnd() | ConvertFrom-Json -Depth 8
foreach ($encodedValue in $values) {
    try {
        $value = $encodedValue | ConvertFrom-Json -Depth 8
        ConvertTo-JstiDiagnosticProjection $value | ConvertTo-Json -Depth 8 -Compress
    }
    catch { [Console]::WriteLine('refused') }
}
"""
        with tempfile.TemporaryDirectory() as directory:
            environment = {key: val for key, val in os.environ.items()
                           if key.upper() in {"PATH", "SYSTEMROOT", "WINDIR", "HOME"}}
            environment.update(TEMP=directory, TMP=directory, TMPDIR=directory,
                               JSTI_PROJECTOR=str(HERE / "FailureDiagnostics.ps1"))
            completed = subprocess.run([os.path.abspath(host), "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", script],
                                       input=json.dumps([json.dumps(value) for value in values]).encode("utf-8"), env=environment, cwd=directory,
                                       capture_output=True, timeout=15, check=False)
        self.assertEqual(completed.returncode, 0, "actual pure refusal-facts projector failed")
        self.assertEqual(completed.stderr, b"")
        rows = completed.stdout.decode("utf-8").splitlines()
        expected = json.loads(json.dumps(value))
        expected["debugger"].pop("exceptionCode")  # Existing PS projection omits null optional codes.
        self.assertEqual(json.loads(rows[0]), expected)
        self.assertEqual(rows[1:], ["refused"] * (len(values) - 1))
        self.assertNotIn(b"PRIVATE", completed.stdout + completed.stderr)
        self.assertLessEqual(len(rows[0].encode("utf-8")), 8192)

    def test_completed_pre_ready_collector_classifies_exact_exit_values_without_replaying(self):
        cases = [(0, "zero"), (42, "otherNonzero"), (-2147483648, "otherNonzero"), (4294967295, "otherNonzero")]
        for code, label in ((0xC0000135, "dllNotFoundStatus"), (0xC000007B, "invalidImageFormatStatus"),
                            (0xC0000139, "entryPointNotFoundStatus")):
            cases.extend(((code, label), (code - (1 << 32), label)))
        for code, label in cases:
            for output in (b"", b"PRIVATE_OUTPUT_CANARY\xff"):
                with self.subTest(code=code, empty=not output):
                    calls = []
                    def runner(argv, environment, directory, budget, seconds, **kwargs):
                        calls.append(argv)
                        if argv[0] != DEBUGGER.CDB_LOCATION:
                            return dict(status="complete", cleanup="clean", exitCode=0, output=b'{"status":"unavailable"}')
                        self.assertEqual(argv[1:8], ["-hd", "-G", "-sins", "-noshell", "-nosqm", "-netsyms:no", "-cf"])
                        self.assertEqual(pathlib.Path(argv[8]).read_text(encoding="ascii"), DEBUGGER.cdb_commands())
                        self.assertEqual(argv[-2:], [self.request()["executable"], "--ui-smoke-test"])
                        self.assertEqual(seconds, 18)
                        return dict(status="complete", cleanup="clean", exitCode=code, output=output)
                    result = self.operate(runner=runner)
                    self.assertEqual([call[0] for call in calls], [self.request()["powershell"], DEBUGGER.CDB_LOCATION])
                    self.assertEqual((result["status"], result["cleanup"]), ("invalid", "clean"))
                    facts = result["debugger"]["refusalFacts"]
                    self.assertEqual(facts.pop("processFacts"), {"exitStatusClass": label,
                                                               "outputClass": "nonempty" if output else "empty"})
                    expected = DEBUGGER.project_debugger(output, code == 0, completion_class="zero" if code == 0 else "nonzero")
                    self.assertEqual(result["debugger"], expected)
                    self.assertNotIn("PRIVATE", json.dumps(result))

    def test_pre_ready_process_facts_omit_non_integer_or_out_of_range_status(self):
        for code in (None, True, False, 0.0, 3221225781.0, "3221225781", -(1 << 31) - 1, 1 << 32):
            with self.subTest(kind=type(code).__name__):
                def runner(argv, *args, **kwargs):
                    return dict(status="complete", cleanup="clean", exitCode=code,
                                output=b"PRIVATE_CANARY" if argv[0] == DEBUGGER.CDB_LOCATION else b'{"status":"unavailable"}')
                result = self.operate(runner=runner)
                self.assertEqual(result["status"], "invalid")
                self.assertNotIn("processFacts", result["debugger"]["refusalFacts"])
                self.assertNotIn("PRIVATE", json.dumps(result))

    def test_process_facts_are_absent_after_ready_or_incomplete_or_failed_collector(self):
        cases = [("complete", "clean", b"JSTI_DIAG_READY\n"),
                 ("complete", "clean", b"JSTI_DIAG_READY\nJSTI_DIAG_READY\n"),
                 ("complete", "clean", self.fixture().replace(b"JSTI_DIAG_END", b"")),
                 ("complete", "clean", b"x" * 65537), ("deadline", "clean", b""),
                 ("truncated", "clean", b""), ("complete", "failed", b"")]
        expected = ("no-reproduction", "invalid", "invalid", "truncated", "deadline", "truncated", "unavailable")
        for (status, cleanup, output), expected_status in zip(cases, expected):
            calls = []
            def runner(argv, *args, **kwargs):
                calls.append(argv[0])
                if argv[0] != DEBUGGER.CDB_LOCATION:
                    return dict(status="complete", cleanup="clean", exitCode=0, output=b'{"status":"unavailable"}')
                return dict(status=status, cleanup=cleanup, exitCode=0, output=output)
            result = self.operate(runner=runner)
            self.assertEqual(result["status"], expected_status)
            self.assertEqual(calls, [self.request()["powershell"], DEBUGGER.CDB_LOCATION])
            self.assertNotIn("processFacts", result["debugger"].get("refusalFacts", {}))

    def test_actual_pre_ready_process_facts_roundtrip_and_fail_closed_at_powershell_boundary(self):
        host = shutil.which("pwsh")
        if host is None:
            self.skipTest("PowerShell unavailable: actual process-facts boundary not executed")
        accepted = []
        for code in (0, 42, 0xC0000135, -1073741701, 0xC0000139):
            for output in (b"", b"PRIVATE_CANARY"):
                def runner(argv, *args, **kwargs):
                    return dict(status="complete", cleanup="clean", exitCode=code if argv[0] == DEBUGGER.CDB_LOCATION else 0,
                                output=output if argv[0] == DEBUGGER.CDB_LOCATION else b'{"status":"unavailable"}')
                accepted.append(self.operate(runner=runner))
        values = list(accepted)
        def changed(change):
            value = json.loads(json.dumps(accepted[-1]))
            change(value)
            values.append(value)
        for key in ("exitStatusClass", "outputClass"):
            for invalid in (None, True, False, 1, -1, 1.5, [], {}, "PRIVATE_CANARY", "nonempty\n", "ZERO"):
                changed(lambda v, key=key, invalid=invalid: v["debugger"]["refusalFacts"]["processFacts"].update({key: invalid}))
            changed(lambda v, key=key: v["debugger"]["refusalFacts"]["processFacts"].pop(key))
        for invalid in (None, True, [], "PRIVATE_CANARY"):
            changed(lambda v, invalid=invalid: v["debugger"]["refusalFacts"].update(processFacts=invalid))
        changed(lambda v: v["debugger"]["refusalFacts"]["processFacts"].update(schema=1))
        changed(lambda v: v["debugger"]["refusalFacts"]["processFacts"].update(OutputClass="nonempty"))
        changed(lambda v: v["debugger"]["refusalFacts"].update(ProcessFacts={}))
        changed(lambda v: v["debugger"]["refusalFacts"].update(completionClass="zero"))
        changed(lambda v: v["debugger"]["refusalFacts"]["processFacts"].update(exitStatusClass="zero"))
        changed(lambda v: v["debugger"]["refusalFacts"].update(reason="fault-boundary"))
        changed(lambda v: v["debugger"]["refusalFacts"]["counts"].update(ready=1))
        for field in ("fault", "end", "modules", "stack", "ip", "moduleRanges", "stackRows"):
            for count in (1, 17):
                def impossible_empty(value, field=field, count=count):
                    value["debugger"]["refusalFacts"]["processFacts"]["outputClass"] = "empty"
                    value["debugger"]["refusalFacts"]["counts"][field] = count
                changed(impossible_empty)
        changed(lambda v: v.update(schema=True))
        script = """
$ErrorActionPreference='Stop'
. $env:JSTI_PROJECTOR
foreach ($encoded in ([Console]::In.ReadToEnd() | ConvertFrom-Json -Depth 8)) {
    try { ConvertTo-JstiDiagnosticProjection ($encoded | ConvertFrom-Json -Depth 8) | ConvertTo-Json -Depth 8 -Compress }
    catch { [Console]::WriteLine('refused') }
}
"""
        with tempfile.TemporaryDirectory() as directory:
            environment = {key: val for key, val in os.environ.items()
                           if key.upper() in {"PATH", "SYSTEMROOT", "WINDIR", "HOME"}}
            environment.update(TEMP=directory, TMP=directory, TMPDIR=directory,
                               JSTI_PROJECTOR=str(HERE / "FailureDiagnostics.ps1"))
            completed = subprocess.run([os.path.abspath(host), "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", script],
                                       input=json.dumps([json.dumps(v) for v in values]).encode("utf-8"), env=environment,
                                       cwd=directory, capture_output=True, timeout=15, check=False)
        self.assertEqual(completed.returncode, 0, "actual pure process-facts projection failed")
        self.assertEqual(completed.stderr, b"")
        rows = completed.stdout.decode("utf-8").splitlines()
        expected = json.loads(json.dumps(accepted))
        for value in expected:
            value["debugger"].pop("exceptionCode")
        self.assertEqual([json.loads(row) for row in rows[:len(accepted)]], expected)
        self.assertEqual(rows[len(accepted):], ["refused"] * (len(values) - len(accepted)))
        self.assertNotIn(b"PRIVATE", completed.stdout + completed.stderr)
        self.assertTrue(all(len(row.encode("utf-8")) <= 8192 for row in rows))

    def test_actual_identity_checks_hash_pe_alias_version_and_between_read_change(self):
        budget = types.SimpleNamespace(remaining=lambda: 20)
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory).resolve() / "SpeakWindows.exe"
            data = FIXTURES.build_pe(["KERNEL32.dll"], machine=ARM64)
            path.write_bytes(data)
            digest = hashlib.sha256(data).hexdigest()
            self.assertEqual(PROCESS.diagnostic_identity(str(path), digest, 1 << 20, budget)[2], len(data))
            with self.assertRaises(ValueError):
                PROCESS.diagnostic_identity(str(path), "a" * 64, 1 << 20, budget)
            path.write_bytes(FIXTURES.build_pe(["KERNEL32.dll"], machine=AMD64))
            with self.assertRaises(ValueError):
                PROCESS.diagnostic_identity(str(path), HOST.sha256_file(path), 1 << 20, budget)
            path.write_bytes(data)
            alias = pathlib.Path(directory).resolve() / "alias.exe"
            alias.symlink_to(path)
            with self.assertRaises(ValueError):
                PROCESS.diagnostic_identity(str(alias), digest, 1 << 20, budget)
            def changed(_):
                path.write_bytes(data + b"changed")
                return DEBUGGER.CDB_VERSION
            with mock.patch.object(PROCESS, "numeric_file_version", side_effect=changed):
                with self.assertRaises(ValueError):
                    PROCESS.diagnostic_identity(str(path), digest, 1 << 20, budget, version=DEBUGGER.CDB_VERSION)

    def test_peek_adapter_reads_only_available_bytes_and_maps_closed_not_idle(self):
        import ctypes
        stream = types.SimpleNamespace(fileno=lambda: 7)
        reader = PROCESS.DiagnosticPipeReader.__new__(PROCESS.DiagnosticPipeReader)
        reader.ctypes, reader.handle = ctypes, lambda fd: fd + 10
        def peek(handle, data, size, read, available, left):
            self.assertEqual(handle, 17)
            available._obj.value = 9
            return 1
        reader.peek = peek
        with mock.patch.object(os, "read", return_value=b"available") as read:
            self.assertEqual(reader.read(stream), (b"available", False))
            read.assert_called_once_with(7, 9)
        with mock.patch.object(os, "read", return_value=b"ava") as read:
            self.assertEqual(reader.read(stream, 3), (b"ava", False))
            read.assert_called_once_with(7, 3)
        with mock.patch.object(os, "read") as read:
            with self.assertRaises(OverflowError):
                reader.read(stream, 0)
            read.assert_not_called()
        reader.peek = lambda *args: 0
        with mock.patch.object(ctypes, "get_last_error", return_value=109, create=True):
            self.assertEqual(reader.read(stream), (b"", True))
        with mock.patch.object(ctypes, "get_last_error", return_value=5, create=True):
            with self.assertRaises(OSError):
                reader.read(stream)

    def test_actual_bounded_runner_caps_splits_drains_both_and_preserves_child_cleanup(self):
        class Process:
            def __init__(self, running=False, fail_wait=False):
                self.stdout, self.stderr = io.BytesIO(), io.BytesIO()
                self.returncode, self.fail_wait, self.killed = (None if running else 0), fail_wait, False
            def poll(self):
                return self.returncode
            def kill(self):
                self.killed, self.returncode = True, -9
            def wait(self, timeout):
                if self.fail_wait or self.returncode is None:
                    raise subprocess.TimeoutExpired("fixed-owned-child", timeout)
                return self.returncode
        budget = types.SimpleNamespace(remaining=lambda: 10)
        row = b"a" * 1023 + b"\n"
        for data, error, expected in ((b"a" * 2048 + b"\n", b"stderr\n", "complete"),
                                      (b"a" * 2049, b"stderr\n", "truncated"),
                                      (row * 65, b"stderr\n", "truncated"),
                                      (row * 33, row * 33, "truncated"),
                                      (row * 32, row * 32, "complete")):
            process = Process()
            remaining, consumed = {process.stdout: data, process.stderr: error}, []
            def read(stream, maximum):
                if not remaining[stream]:
                    return b"", True
                if maximum == 0:
                    raise OverflowError()
                chunk = remaining[stream][:min(1024, maximum)]
                remaining[stream] = remaining[stream][len(chunk):]
                consumed.append(len(chunk))
                return chunk, False
            def launch(argv, **options):
                self.assertEqual(options["creationflags"], 0)
                self.assertEqual(options["executable"], argv[0])
                self.assertTrue(options["close_fds"])
                self.assertEqual(options["bufsize"], 0)
                return process
            result = PROCESS.bounded_diagnostic_process(["fixed-owned-cdb"], {}, "owned", budget, 5,
                     launch=launch, pipe_factory=lambda: types.SimpleNamespace(read=read))
            self.assertEqual(result["status"], expected)
            self.assertLessEqual(len(result["output"]), 65536)
            self.assertLessEqual(sum(consumed), 65536)
            if len(data) + len(error) >= 65536 and expected == "complete":
                self.assertEqual(sum(consumed), 65536)
            if len(data) + len(error) > 65536 and not any(len(line) > 2048 for line in data.splitlines()):
                self.assertEqual(sum(consumed), 65536)
                self.assertTrue(any(remaining.values()))
            self.assertEqual(result["cleanup"], "clean")
            self.assertTrue(process.stdout.closed and process.stderr.closed)
        for fail_wait in (False, True):
            process = Process(running=True, fail_wait=fail_wait)
            result = PROCESS.bounded_diagnostic_process(["fixed"], {}, "owned", budget, .03,
                     launch=lambda *a, **k: process,
                     pipe_factory=lambda: types.SimpleNamespace(read=lambda *_: (b"", False)),
                     clock=Clock(.01), sleep=lambda _: None)
            self.assertEqual(result["status"], "deadline")
            self.assertTrue(process.killed)
            self.assertEqual(result["cleanup"], "failed" if fail_wait else "clean")
        # Child exit is not pipe EOF / descendant cleanup. The outer PS job is
        # still authoritative even when this one exact child already exited.
        process = Process()
        result = PROCESS.bounded_diagnostic_process(["fixed"], {}, "owned", budget, .03,
                 launch=lambda *a, **k: process,
                 pipe_factory=lambda: types.SimpleNamespace(read=lambda *_: (b"", False)),
                 clock=Clock(.01), sleep=lambda _: None)
        self.assertEqual(result["status"], "deadline")
        self.assertFalse(process.killed)
        self.assertTrue(process.stdout.closed and process.stderr.closed)

    def test_cli_invalid_input_is_one_bounded_closed_json_without_private_error(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            NATIVE.dispatch_main(["standalone-diagnostic", "--request", "private-canary"])
        self.assertEqual(len(output.getvalue().splitlines()), 1)
        result = json.loads(output.getvalue())
        self.assertEqual(set(result), {"schema", "status", "cleanup", "applicationError", "debugger"})
        self.assertIn(result["status"], DEBUGGER.STANDALONE_STATUSES)
        self.assertLess(len(output.getvalue()), 8192)
        self.assertNotIn("private", output.getvalue())


class DiagnosticBootstrapTests(unittest.TestCase):
    def test_actual_powershell_ownership_controller_with_pure_fake_adapter(self):
        host = shutil.which("pwsh")
        if host is None:
            self.skipTest("PowerShell unavailable: actual bootstrap fake checks not executed")
        # No native adapter, Add-Type, debugger or target is reachable in this
        # explicit inert import. Keep the fixture's environment and temp owned.
        with tempfile.TemporaryDirectory() as directory:
            environment = {key: value for key, value in os.environ.items()
                           if key.upper() in {"PATH", "SYSTEMROOT", "WINDIR", "HOME"}}
            environment.update(TEMP=directory, TMP=directory, TMPDIR=directory)
            completed = subprocess.run([
                os.path.abspath(host), "-NoLogo", "-NoProfile", "-NonInteractive", "-File",
                str(HERE / "test-failure-diagnostic-bootstrap.ps1")],
                cwd=directory, env=environment, capture_output=True, timeout=30, check=False)
        self.assertEqual(completed.returncode, 0, "actual PowerShell bootstrap fake checks failed")
        self.assertEqual(completed.stdout.strip(), b"Diagnostic bootstrap pure-fake checks passed.")
        self.assertEqual(completed.stderr, b"")


if __name__ == "__main__":
    unittest.main()
