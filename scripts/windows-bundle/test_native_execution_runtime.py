#!/usr/bin/env python3
"""The pinned diagnostic runtime and preparation facts (native_execution_runtime).

Unit tests for verify-native-execution.py; Windows process calls are faked.
"""
import hashlib
import json
import ntpath
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
import native_execution_runtime as RUNTIME  # noqa: E402
import windows_targets  # noqa: E402
from native_execution_fakes import (  # noqa: E402
    AMD64,
    ARM64,
    FIXTURES,
    PE,
    StandaloneRequests,
)


class DiagnosticRuntimeClosureTests(unittest.TestCase):
    def setUp(self):
        # macOS temp aliases must not masquerade as an injected runtime symlink.
        self.enterContext(mock.patch.object(tempfile, "tempdir", str(pathlib.Path(tempfile.gettempdir()).resolve())))
        self.directory = tempfile.TemporaryDirectory(prefix="owned-diagnostic-runtime-")
        self.addCleanup(self.directory.cleanup)
        self.root = pathlib.Path(self.directory.name)
        self.source, self.config = self.root / "source", self.root / "config"
        self.source.mkdir(); self.config.mkdir()
        self.parent = r"C:\Users\Owned\AppData\Local\Programs\Swift\Runtimes\6.2.3\usr\bin"
        policy = json.loads((HERE / "runtime-policy.json").read_text(encoding="utf-8"))
        lock = json.loads((HERE / "swift-runtime-lock-arm64.json").read_text(encoding="utf-8"))
        self.names = policy["swiftRuntimeModules"][:14]
        self.data = FIXTURES.build_pe(["KERNEL32.dll"], machine=ARM64, dll=True)
        self.rows = []
        for name in self.names:
            (self.source / name).write_bytes(self.data)
            row = next(row for row in lock["files"] if row["path"] == name)
            row.update(bytes=len(self.data), sha256=hashlib.sha256(self.data).hexdigest())
            self.rows.append(dict(name=name, path=self.parent + "\\" + name, bytes=row["bytes"], sha256=row["sha256"]))
        # Retain actual canonical installer provenance/policy; only the14 owned
        # synthetic PE payload rows replace real runtime bytes for this fixture.
        (self.config / "runtime-policy.json").write_text(json.dumps(policy), encoding="utf-8")
        (self.config / "swift-runtime-lock-arm64.json").write_text(json.dumps(lock), encoding="utf-8")
        self.real_path = pathlib.Path

    def mapped_path(self, value):
        if isinstance(value, str) and value == self.parent:
            return self.source
        if isinstance(value, str) and value.startswith(self.parent + "\\"):
            return self.source / value[len(self.parent) + 1:]
        return self.real_path(value)

    def operate(self, rows=None, runner=None, api=None):
        fixture = StandaloneRequests()
        with mock.patch.object(RUNTIME, "HERE", self.config), \
                mock.patch.object(pathlib, "Path", side_effect=self.mapped_path):
            return fixture.operate(value=fixture.request(runtimeModules=self.rows if rows is None else rows),
                                   runner=runner, api=api)

    def test_actual_canonical_layout_uses_existing_arm_installer_pin_and_policy(self):
        version, layout = RUNTIME.diagnostic_runtime_layout()
        policy = json.loads((HERE / "runtime-policy.json").read_text(encoding="utf-8"))
        lock = json.loads((HERE / "swift-runtime-lock-arm64.json").read_text(encoding="utf-8"))
        self.assertEqual(version, windows_targets.swift_runtime_installer("arm64")[0])
        self.assertEqual(set(layout), set(policy["swiftRuntimeModules"]))
        self.assertEqual(layout, {row["path"]: row for row in lock["files"] if row["path"] in layout})
        source = self.config / "swift-runtime-lock-arm64.json"
        value = json.loads(source.read_text(encoding="utf-8")); value["installer"]["sha256"] = "0" * 64
        source.write_text(json.dumps(value), encoding="utf-8")
        with mock.patch.object(RUNTIME, "HERE", self.config), self.assertRaises(ValueError):
            RUNTIME.diagnostic_runtime_layout()

    def test_actual_operation_copies_only_verified_fourteen_and_changes_only_debugger_path(self):
        (self.source / "PRIVATE_UNOBSERVED_CANARY.dll").write_bytes(b"never admitted")
        calls, private_paths = [], []
        def runner(argv, environment, directory, budget, seconds, **kwargs):
            calls.append(argv[0])
            system = ntpath.join(environment.get("SystemRoot", r"C:\Windows"), "System32")
            if argv[0] != DEBUGGER.CDB_LOCATION:
                self.assertEqual(environment["PATH"], system)
                return dict(status="complete", cleanup="clean", exitCode=0, output=b'{"status":"unavailable"}')
            private = self.real_path(directory) / "runtime"; private_paths.append(private)
            self.assertEqual(environment["PATH"], system + ";" + str(private))
            self.assertNotIn(self.parent, environment["PATH"])
            self.assertNotIn("PRIVATE_INHERITED", json.dumps(environment))
            self.assertEqual(set(p.name for p in private.iterdir()), set(self.names))
            for path in private.iterdir():
                self.assertEqual(path.read_bytes(), self.data)
            self.assertEqual(argv[1:8], ["-hd", "-G", "-sins", "-noshell", "-nosqm", "-netsyms:no", "-cf"])
            self.assertEqual(self.real_path(argv[8]).read_text(encoding="ascii"), DEBUGGER.cdb_commands())
            self.assertEqual(argv[-2:], [StandaloneRequests().request()["executable"], "--ui-smoke-test"])
            self.assertEqual(seconds, 18)
            return dict(status="complete", cleanup="clean", exitCode=0xC0000135, output=b"")
        with mock.patch.dict(os.environ, {"PATH": "PRIVATE_INHERITED", "PROVIDER_TOKEN": "PRIVATE_INHERITED"}):
            result = self.operate(runner=runner)
        self.assertEqual(calls, [StandaloneRequests().request()["powershell"], DEBUGGER.CDB_LOCATION])
        self.assertEqual((result["status"], result["cleanup"]), ("invalid", "clean"))
        self.assertTrue(private_paths)
        self.assertFalse(private_paths[0].exists())
        self.assertNotIn(self.parent, json.dumps(result))
        self.assertNotIn("PRIVATE", json.dumps(result))

    def test_supplied_malformed_runtime_context_never_downgrades_to_legacy_or_launches(self):
        values = [None, [], self.rows[:13], self.rows + self.rows[:1], True, "PRIVATE_CANARY"]
        def change(index, **changes):
            rows = json.loads(json.dumps(self.rows)); rows[index].update(changes); return rows
        values.extend(change(0, **{key: value}) for key, value in (("bytes", True), ("bytes", 0),
            ("bytes", 67108865), ("bytes", 1.5), ("sha256", "PRIVATE_CANARY"), ("path", r"\\server\a.dll"),
            ("path", self.parent + r"\..\a.dll"), ("path", self.parent + ';x\\' + self.names[0]),
            ("name", "../a.dll"), ("extra", "PRIVATE_CANARY")))
        values.append(change(1, name=self.rows[0]["name"], path=self.rows[0]["path"]))
        values.append(change(1, name=self.rows[0]["name"].upper(), path=self.parent + "\\" + self.rows[0]["name"].upper()))
        values.append(change(0, path=self.parent.replace("Owned", "Other") + "\\" + self.names[0]))
        too_large = json.loads(json.dumps(self.rows))
        for row in too_large: row["bytes"] = 5 << 20
        values.append(too_large)
        for rows in values:
            with self.subTest(kind=type(rows).__name__):
                runner = mock.Mock(side_effect=AssertionError("no collector"))
                result = self.operate(rows=rows, runner=runner) if rows is not None else DEBUGGER.standalone_diagnostic(
                    StandaloneRequests().encode(StandaloneRequests().request(runtimeModules=None)), runner=runner)
                runner.assert_not_called()
                self.assertEqual(result["status"], "unavailable")
                self.assertNotIn("PRIVATE", json.dumps(result))

    def test_pinned_missing_foreign_alias_and_changed_sources_refuse_before_cdb(self):
        for mode in ("missing", "size", "hash", "foreign", "not-dll", "file-alias", "directory-alias", "changed"):
            with self.subTest(mode=mode):
                first = self.source / self.names[0]; first.write_bytes(self.data)
                calls = []
                def runner(argv, *args, **kwargs):
                    calls.append(argv[0])
                    self.assertNotEqual(argv[0], DEBUGGER.CDB_LOCATION)
                    return dict(status="complete", cleanup="clean", exitCode=0, output=b'{"status":"unavailable"}')
                if mode == "missing": first.unlink()
                if mode == "size": first.write_bytes(self.data + b"x")
                if mode == "hash": first.write_bytes(self.data[:-1] + bytes([self.data[-1] ^ 1]))
                if mode in ("foreign", "not-dll"):
                    data = FIXTURES.build_pe(["KERNEL32.dll"], machine=AMD64 if mode == "foreign" else ARM64,
                                                dll=mode == "foreign")
                    first.write_bytes(data)
                    lock = json.loads((self.config / "swift-runtime-lock-arm64.json").read_text(encoding="utf-8"))
                    pinned = next(row for row in lock["files"] if row["path"] == self.names[0])
                    pinned.update(bytes=len(data), sha256=hashlib.sha256(data).hexdigest())
                    self.rows[0].update(bytes=len(data), sha256=pinned["sha256"])
                    (self.config / "swift-runtime-lock-arm64.json").write_text(json.dumps(lock), encoding="utf-8")
                if mode == "file-alias":
                    first.unlink(); first.symlink_to(self.source / self.names[1])
                source = self.source
                if mode == "directory-alias":
                    moved = source.with_name("source-original"); source.rename(moved); source.symlink_to(moved, target_is_directory=True)
                real_image = PE.PEImage
                def changed_image(*args, **kwargs):
                    image = real_image(*args, **kwargs)
                    if mode == "changed" and not getattr(changed_image, "done", False):
                        changed_image.done = True; first.write_bytes(self.data + b"changed")
                    return image
                with mock.patch.object(PE, "PEImage", side_effect=changed_image):
                    result = self.operate(runner=runner)
                self.assertEqual(calls, [StandaloneRequests().request()["powershell"]])
                self.assertEqual(result["status"], "unavailable")
                self.assertNotIn(self.parent, json.dumps(result))
                if mode == "directory-alias": source.unlink(); moved.rename(source)
                if first.is_symlink(): first.unlink()
                first.write_bytes(self.data)
                lock = json.loads((self.config / "swift-runtime-lock-arm64.json").read_text(encoding="utf-8"))
                pinned = next(row for row in lock["files"] if row["path"] == self.names[0])
                pinned.update(bytes=len(self.data), sha256=hashlib.sha256(self.data).hexdigest())
                self.rows[0].update(bytes=len(self.data), sha256=pinned["sha256"])
                (self.config / "swift-runtime-lock-arm64.json").write_text(json.dumps(lock), encoding="utf-8")

    def test_copy_recheck_private_mutation_exclusive_destination_and_budget_refuse(self):
        for mode in ("copy-mutation", "extra-copy", "deadline", "preexisting"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                calls = [0]
                def remaining():
                    calls[0] += 1
                    return 2 if mode == "deadline" and calls[0] >= 3 else 20
                budget = types.SimpleNamespace(remaining=remaining)
                real_bytes = RUNTIME.diagnostic_runtime_bytes
                def tampered(path, row, budget):
                    if mode == "copy-mutation" and path.parent.name == "runtime":
                        path.write_bytes(b"x" * row["bytes"])
                    if mode == "extra-copy" and path.parent.name == "runtime":
                        (path.parent / "PRIVATE_UNOBSERVED_CANARY.dll").write_bytes(self.data)
                    return real_bytes(path, row, budget)
                if mode == "preexisting": (self.real_path(directory) / "runtime").mkdir()
                with mock.patch.object(RUNTIME, "HERE", self.config), \
                        mock.patch.object(pathlib, "Path", side_effect=self.mapped_path), \
                        mock.patch.object(RUNTIME, "diagnostic_runtime_bytes", side_effect=tampered), \
                        self.assertRaises((ValueError, TimeoutError, FileExistsError)):
                    RUNTIME.prepare_diagnostic_runtime(self.rows, directory, budget)


    def test_actual_powershell_closed_runtime_projection_refuses_unknown_and_partial_fields(self):
        host = shutil.which("pwsh")
        if host is None:
            self.skipTest("PowerShell unavailable: actual runtime projection not executed")
        values = [self.rows]
        for kind in ("partial", "null", "bool", "unknown", "case", "duplicate", "mixed", "range", "hash"):
            rows = json.loads(json.dumps(self.rows))
            if kind == "partial": rows.pop()
            if kind == "null": rows = None
            if kind == "bool": rows[0]["bytes"] = True
            if kind == "unknown": rows[0]["private"] = "PRIVATE_CANARY"
            if kind == "case": rows[0]["Name"] = rows[0].pop("name")
            if kind == "duplicate": rows[1] = rows[0]
            if kind == "mixed": rows[0]["path"] = rows[0]["path"].replace("Owned", "Other")
            if kind == "range": rows[0]["bytes"] = 67108865
            if kind == "hash": rows[0]["sha256"] = "PRIVATE_CANARY"
            values.append(rows)
        script = r'''
$ErrorActionPreference='Stop'
. $env:JSTI_PROJECTOR
foreach ($encoded in ([Console]::In.ReadToEnd() | ConvertFrom-Json -Depth 8)) {
    try { ConvertTo-JstiDiagnosticRuntimeModules ($encoded | ConvertFrom-Json -Depth 8) | ConvertTo-Json -Depth 4 -Compress }
    catch { [Console]::WriteLine('refused') }
}
'''
        environment = dict(os.environ, JSTI_PROJECTOR=str(HERE / "FailureDiagnostics.ps1"))
        completed = subprocess.run([host, "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", script],
            input=json.dumps([json.dumps(value) for value in values]).encode("utf-8"), cwd=self.root, env=environment,
            capture_output=True, timeout=15, check=False)
        self.assertEqual(completed.returncode, 0)
        self.assertEqual(completed.stderr, b"")
        lines = completed.stdout.decode("utf-8").splitlines()
        self.assertEqual(json.loads(lines[0]), self.rows)
        self.assertEqual(lines[1:], ["refused"] * (len(values) - 1))
        self.assertNotIn(b"PRIVATE", completed.stdout)

    def test_actual_native_adapter_and_standalone_request_preserve_observations_without_launch(self):
        host = shutil.which("pwsh")
        if host is None:
            self.skipTest("PowerShell unavailable: actual runtime request not executed")
        script = r'''
$ErrorActionPreference='Stop'
. $env:JSTI_PROJECTOR
$workspace=(Get-Location).Path; $systemRoot='C:\Windows'; $isolatedPath='C:\Windows\System32'
$script:captured=$null; $script:bootstrapCalls=0
$identity=(Get-Item Function:Get-JstiDiagnosticIdentity).ScriptBlock
$adapter=(Get-Item Function:New-JstiDiagnosticAdapter).ScriptBlock
$bootstrap=(Get-Item Function:Invoke-JstiDiagnosticBootstrap).ScriptBlock
try {
    Set-Item Function:Get-JstiDiagnosticIdentity { param($path,$names) return @{Path=$path;Hash=('0'*64)} }
    Set-Item Function:New-JstiDiagnosticAdapter {
        param($Frequency,$State) $script:ownedState=$State; return @{}
    }
    Set-Item Function:Invoke-JstiDiagnosticBootstrap {
        param($Adapter,$Request,$DeadlineTicks,$Frequency)
        $script:bootstrapCalls++
        $encoded=$Request.Arguments[-1].Replace('-','+').Replace('_','/')
        $encoded += '=' * ((4 - $encoded.Length % 4) % 4)
        $bytes=[Convert]::FromBase64String($encoded)
        if ($bytes.Length -gt 8192) { throw 'PRIVATE_CANARY' }
        $script:captured=[Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json -Depth 8
        $response=[Text.Encoding]::UTF8.GetBytes('{"schema":1,"status":"unavailable","cleanup":"clean","applicationError":{"status":"unavailable"},"debugger":{"status":"unavailable","frames":[]}}')
        $script:ownedState.Output.Write($response,0,$response.Length)
        return @{status='finished';cleanup='complete';resumed=$true;streamBytes=$response.Length}
    }
    $rows=[Console]::In.ReadToEnd() | ConvertFrom-Json -Depth 8
    $frequency=[Diagnostics.Stopwatch]::Frequency
    $deadline=[Diagnostics.Stopwatch]::GetTimestamp()+30*$frequency
    $moment=[DateTime]::UtcNow.ToString('o')
    $modules=@($rows | ForEach-Object { @{name=$_.name;path=$_.path;bytes=$_.bytes;sha256=$_.sha256;dll=$true;native=$true;architecture='arm64'} })
    $run=@{label='ui-smoke-test';arguments=@('--ui-smoke-test');timedOut=$false;processMachine='arm64';nativeMachine='arm64';
        exitCode=3221226356L;failures=@('owned abnormal exit');modulesOutsideSystemRoot=$modules;
        executable=@{name='SpeakWindows.exe';path='C:\Owned\SpeakWindows.exe';sha256=('0'*64);architecture='arm64';native=$true;dll=$false};
        diagnosticOwnerContext=@{schema=1;originalPid=314;startedUTC=$moment;endedUTC=$moment;deadlineTicks=$deadline;frequency=$frequency;exitCode=-1073740940}}
    $before=$run | ConvertTo-Json -Depth 12 -Compress
    $setup=@{Host=@{Path='C:\Owned\pwsh.exe';Hash=('0'*64)};Python=@{Path='C:\Owned\python.exe';Hash=('0'*64)}}
    $result=Invoke-JstiNativeFailureDiagnostic $setup $run 'C:\Owned\SpeakWindows.exe' ('0'*64) $deadline $frequency
    @{request=$script:captured;result=$result;calls=$script:bootstrapCalls;unchanged=(($run|ConvertTo-Json -Depth 12 -Compress)-ceq$before)} |
        ConvertTo-Json -Depth 12 -Compress
} finally {
    Set-Item Function:Get-JstiDiagnosticIdentity $identity
    Set-Item Function:New-JstiDiagnosticAdapter $adapter
    Set-Item Function:Invoke-JstiDiagnosticBootstrap $bootstrap
}
'''
        environment = dict(os.environ, JSTI_PROJECTOR=str(HERE / "FailureDiagnostics.ps1"))
        completed = subprocess.run([host, "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", script],
            input=json.dumps(self.rows).encode("utf-8"), cwd=self.root, env=environment,
            capture_output=True, timeout=15, check=False)
        self.assertEqual(completed.returncode, 0)
        self.assertEqual(completed.stderr, b"")
        value = json.loads(completed.stdout)
        self.assertEqual(value["calls"], 1)
        self.assertTrue(value["unchanged"])
        self.assertEqual(value["request"]["runtimeModules"], self.rows)
        self.assertEqual(set(value["request"]), DEBUGGER.STANDALONE_KEYS | {"runtimeModules"})
        self.assertEqual(value["result"]["status"], "unavailable")
        self.assertTrue(value["result"]["originalFailurePreserved"])
        DEBUGGER.diagnostic_request(StandaloneRequests().encode(value["request"]))
        self.assertEqual(list(self.root.glob("failure-diagnostic-*/runtime")), [])
        self.assertNotIn(b"PRIVATE", completed.stdout)



    def test_reparse_attribute_and_noncanonical_version_or_location_refuse(self):
        alias = types.SimpleNamespace(parents=(), lstat=lambda: types.SimpleNamespace(st_file_attributes=0x400))
        with self.assertRaises(ValueError):
            RUNTIME.diagnostic_runtime_stamp(alias)
        for parent in (self.parent.replace("6.2.3", "6.2.4"), r"C:\Untrusted\Swift\Runtimes\6.2.3\usr\bin"):
            rows = [dict(row, path=parent + "\\" + row["name"]) for row in self.rows]
            with tempfile.TemporaryDirectory() as directory, mock.patch.object(RUNTIME, "HERE", self.config), \
                    self.assertRaises(ValueError):
                RUNTIME.prepare_diagnostic_runtime(rows, directory, types.SimpleNamespace(remaining=lambda: 20))
            self.assertFalse((self.real_path(directory) / "runtime").exists())


    def test_actual_copy_rechecks_original_minimum_start_window_before_cdb(self):
        for ended_ticks in (24000, 27000, 23000):
            with self.subTest(remaining=(30000 - ended_ticks) / 1000):
                now, calls, private_paths = [10000], [], []
                request = StandaloneRequests().request(runtimeModules=self.rows)
                before = json.loads(json.dumps(request))
                original_prepare = RUNTIME.prepare_diagnostic_runtime
                def consumed_copy(*args):
                    runtime = original_prepare(*args)
                    private_paths.append(self.real_path(runtime))
                    now[0] = ended_ticks
                    return runtime
                def runner(argv, environment, directory, budget, seconds, **kwargs):
                    calls.append(argv[0])
                    if argv[0] == DEBUGGER.CDB_LOCATION:
                        self.assertEqual(seconds, 5)
                        return dict(status="complete", cleanup="clean", exitCode=0, output=b"JSTI_DIAG_READY\n")
                    return dict(status="complete", cleanup="clean", exitCode=0, output=b'{"status":"unavailable"}')
                with mock.patch.object(RUNTIME, "HERE", self.config), \
                        mock.patch.object(pathlib, "Path", side_effect=self.mapped_path), \
                        mock.patch.object(DEBUGGER, "prepare_diagnostic_runtime", side_effect=consumed_copy):
                    result = StandaloneRequests().operate(value=request,
                        api=StandaloneRequests().api(ticks=lambda: now[0]), runner=runner)
                self.assertEqual(request, before)
                self.assertEqual(request["exitCode"], -1073740940)
                self.assertEqual(result["cleanup"], "clean")
                self.assertTrue(private_paths)
                self.assertTrue(all(not path.exists() for path in private_paths))
                expected = [request["powershell"]]
                if ended_ticks == 23000:
                    expected.append(DEBUGGER.CDB_LOCATION)
                    self.assertEqual(result["status"], "no-reproduction")
                else:
                    self.assertEqual(result["status"], "deadline")
                    self.assertEqual(result["debugger"]["status"], "deadline")
                self.assertEqual(calls, expected)


class DiagnosticPreparationFactsTests(unittest.TestCase):
    def test_early_phase_cleanup_coherence_refuses_all_six_unreachable_combinations(self):
        cases = 0
        for phase in ("app-identity", "host-identity", "scratch-setup"):
            for cleanup, event_status in (("not-started", "unavailable"), ("clean", "unavailable"), ("clean", "observed")):
                value = DEBUGGER.diagnostic_result("unavailable", cleanup)
                value["applicationError"]["status"] = event_status
                value["debugger"]["preparationFacts"] = {"lastPhase": phase, "errorCategory": "filesystem"}
                before = json.loads(json.dumps(value))
                DEBUGGER._retire_preparation_facts(value, types.SimpleNamespace(remaining=lambda: 20), {})
                accepted = cleanup == "not-started" and event_status == "unavailable"
                self.assertEqual("preparationFacts" in value["debugger"], accepted)
                before["debugger"].pop("preparationFacts")
                value["debugger"].pop("preparationFacts", None)
                self.assertEqual(value, before)
                cases += 1
        self.assertEqual(cases, 9)

    def test_identity_exceptions_are_typed_only_after_admission_and_do_not_format_errors(self):
        fixture = StandaloneRequests()
        class PrivateError(RuntimeError):
            def __str__(self):
                raise AssertionError("must not format private error")
        for failure, category in ((ValueError("PRIVATE_PATH"), "validation"),
                                  (PermissionError("PRIVATE_PATH"), "filesystem"), (PrivateError(), "unexpected")):
            for failed_call, phase in ((1, "app-identity"), (2, "host-identity"), (3, "cdb-identity"),
                                       (4, "identity-recheck"), (5, "identity-recheck")):
                calls = []
                def identity(path, *args, **kwargs):
                    calls.append(path)
                    if len(calls) == failed_call:
                        raise failure
                    return path, "snapshot"
                value = fixture.request()
                before = dict(value)
                result = fixture.operate(value=value, identity=identity)
                self.assertEqual(value, before)
                self.assertEqual(result["status"], "unavailable")
                self.assertEqual(result["debugger"]["preparationFacts"],
                                 {"lastPhase": phase, "errorCategory": category})
                self.assertEqual(result["cleanup"], "not-started" if failed_call < 3 else "clean")
                self.assertNotIn("PRIVATE", json.dumps(result))
        with mock.patch.object(tempfile, "TemporaryDirectory", side_effect=PermissionError("PRIVATE_DIRECTORY")):
            result = fixture.operate()
        self.assertEqual(result["debugger"]["preparationFacts"],
                         {"lastPhase": "scratch-setup", "errorCategory": "filesystem"})
        identity = mock.Mock(side_effect=PrivateError())
        result = fixture.operate(identity=identity, api=fixture.api(admitted=lambda _: False))
        identity.assert_not_called()
        self.assertNotIn("preparationFacts", result["debugger"])

    def test_exact_cdb_unavailable_return_and_mixed_event_paths_preserve_existing_results(self):
        fixture = StandaloneRequests()
        for event_status in ("complete", "unavailable", "deadline", "truncated"):
            for cdb_status in ("unavailable", "deadline", "truncated", "unknown"):
                calls = []
                def runner(argv, *args, **kwargs):
                    calls.append(argv[0])
                    return dict(status=event_status if len(calls) == 1 else cdb_status,
                                cleanup="clean", exitCode=0, output=b'{"status":"unavailable"}')
                result = fixture.operate(runner=runner)
                self.assertEqual(calls, [fixture.request()["powershell"], DEBUGGER.CDB_LOCATION])
                self.assertEqual(result["status"], cdb_status if cdb_status in DEBUGGER.STANDALONE_STATUSES else "unavailable")
                facts = result["debugger"].get("preparationFacts")
                if cdb_status == "unavailable" and event_status in ("complete", "unavailable"):
                    self.assertEqual(facts, {"lastPhase": "cdb-runner", "errorCategory": "returned-unavailable"})
                else:
                    self.assertIsNone(facts)
        for event_status in ("unavailable", "deadline", "truncated"):
            def runner(argv, *args, **kwargs):
                return dict(status=event_status, cleanup="clean", exitCode=0, output=b'{"status":"unavailable"}')
            def identity(path, *args, **kwargs):
                if path == DEBUGGER.CDB_LOCATION:
                    raise OSError("PRIVATE_NATIVE_ERROR")
                return path, "snapshot"
            result = fixture.operate(identity=identity, runner=runner)
            self.assertEqual(result["status"], "unavailable")
            self.assertEqual("preparationFacts" in result["debugger"], event_status == "unavailable")

    def test_runtime_read_copy_and_recheck_failures_use_actual_owned_payload_operations(self):
        for operation, phase, category in (("read", "runtime-source", "filesystem"),
                                           ("copy", "runtime-copy", "filesystem"),
                                           ("recheck", "runtime-recheck", "validation")):
            fixture = DiagnosticRuntimeClosureTests()
            fixture.setUp()
            try:
                original_read = RUNTIME.diagnostic_runtime_bytes
                original_open = fixture.real_path.open
                reads = []
                def read(path, row, budget):
                    reads.append(path)
                    if operation == "read" and path.parent == fixture.source:
                        raise PermissionError("PRIVATE_FILE")
                    if operation == "recheck" and path.parent.name == "runtime":
                        raise ValueError("PRIVATE_HASH")
                    return original_read(path, row, budget)
                def opened(path, *args, **kwargs):
                    if operation == "copy" and args and args[0] == "xb":
                        raise PermissionError("PRIVATE_DESTINATION")
                    return original_open(path, *args, **kwargs)
                with mock.patch.object(RUNTIME, "diagnostic_runtime_bytes", side_effect=read), \
                        mock.patch.object(fixture.real_path, "open", autospec=True, side_effect=opened):
                    result = fixture.operate()
                self.assertEqual(result["status"], "unavailable")
                self.assertEqual(result["cleanup"], "clean")
                self.assertEqual(result["debugger"]["preparationFacts"],
                                 {"lastPhase": phase, "errorCategory": category})
                self.assertNotIn("PRIVATE", json.dumps(result))
                if operation == "recheck":
                    self.assertEqual(len([x for x in reads if x.parent == fixture.source]), 14)
                    self.assertTrue(reads[-1].parent.name == "runtime")
                    self.assertFalse(reads[-1].parent.exists())
            finally:
                fixture.doCleanups()

    def test_cdb_return_facts_are_retired_after_context_exit_and_cleanup_failure(self):
        fixture = StandaloneRequests()
        original = tempfile.TemporaryDirectory
        for outcome in ("cutoff", "cleanup"):
            now = [10000]
            class OwnedDirectory:
                def __init__(self, *args, **kwargs):
                    self.owned = original(*args, **kwargs)
                    self.name = self.owned.name
                def __enter__(self):
                    return self.owned.__enter__()
                def __exit__(self, *args):
                    if outcome == "cleanup":
                        raise PermissionError("PRIVATE_CLEANUP")
                    self.owned.__exit__(*args)
                    now[0] = 29000
                def cleanup(self):
                    self.owned.cleanup()
            directories = []
            def directory(*args, **kwargs):
                owned = OwnedDirectory(*args, **kwargs)
                directories.append(owned)
                return owned
            def runner(*args, **kwargs):
                return dict(status="unavailable", cleanup="clean", exitCode=0, output=b"")
            try:
                with mock.patch.object(tempfile, "TemporaryDirectory", side_effect=directory):
                    result = fixture.operate(api=fixture.api(ticks=lambda: now[0]), runner=runner)
                self.assertEqual(result["status"], "unavailable")
                self.assertNotIn("preparationFacts", result["debugger"])
                if outcome == "cleanup":
                    self.assertEqual(result["cleanup"], "failed")
            finally:
                for owned in directories:
                    owned.cleanup()

    def test_actual_python_exception_facts_roundtrip_through_strict_powershell_projection(self):
        host = shutil.which("pwsh")
        if host is None:
            self.skipTest("PowerShell unavailable: preparation facts boundary not executed")
        def identity(*args, **kwargs):
            raise PermissionError("PRIVATE_CANARY")
        value = StandaloneRequests().operate(identity=identity)
        script = r'''
$ErrorActionPreference='Stop'
. $env:JSTI_PROJECTOR
$value=[Console]::In.ReadToEnd() | ConvertFrom-Json -Depth 8
ConvertTo-JstiDiagnosticProjection $value | ConvertTo-Json -Depth 8 -Compress
'''
        with tempfile.TemporaryDirectory() as directory:
            environment = dict(os.environ, JSTI_PROJECTOR=str(HERE / "FailureDiagnostics.ps1"))
            completed = subprocess.run([host, "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", script],
                input=json.dumps(value).encode("utf-8"), cwd=directory, env=environment,
                capture_output=True, timeout=15, check=False)
        self.assertEqual(completed.returncode, 0)
        self.assertEqual(completed.stderr, b"")
        projected = json.loads(completed.stdout)
        self.assertEqual(projected["debugger"]["preparationFacts"], value["debugger"]["preparationFacts"])
        self.assertEqual(projected["status"], "unavailable")
        self.assertNotIn("PRIVATE", json.dumps(projected))


if __name__ == "__main__":
    unittest.main()
