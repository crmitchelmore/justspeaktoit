#!/usr/bin/env python3
"""Unit tests for verify-native-execution.py; Windows process calls are faked."""
import contextlib
import importlib.util
import io
import json
import os
import pathlib
import sys
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent
sys.dont_write_bytecode = True


def load(name, file_name):
    spec = importlib.util.spec_from_file_location(name, HERE / file_name)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


NATIVE = load("verify_native_execution", "verify-native-execution.py")
BUNDLE_TESTS = load("test_windows_bundle", "test_windows_bundle.py")
PE = NATIVE.windows_pe
AMD64, ARM64 = PE.IMAGE_FILE_MACHINE_AMD64, PE.IMAGE_FILE_MACHINE_ARM64


class FakeAPI:
    def __init__(self, machine=ARM64, native=ARM64, wow64=0, modules=(), machine_error=False):
        self.machine, self.native, self.wow64_machine = machine, native, wow64
        self.samples, self.machine_error = [list(sample) for sample in modules], machine_error
        self.closed = []

    def open(self, pid):
        return ("handle", pid)

    def close(self, handle):
        self.closed.append(handle)

    def current(self):
        return "current"

    def wow64(self, handle):
        return self.wow64_machine, self.native

    def process_machine(self, handle):
        if self.machine_error:
            raise OSError(87, "GetProcessInformation(ProcessMachineTypeInfo) failed")
        return self.machine, 1

    def modules(self, handle, known):
        return self.samples.pop(0) if len(self.samples) > 1 else (self.samples[0] if self.samples else [])


class FakeProcess:
    def __init__(self, polls=2, exit_code=0):
        self.pid, self.polls, self.exit_code = 4242, polls, exit_code
        self.returncode, self.killed = None, False

    def poll(self):
        self.polls -= 1
        if self.polls <= 0:
            self.returncode = self.exit_code
        return self.returncode

    def kill(self):
        self.killed = True
        self.returncode = 1

    def wait(self):
        return self.returncode


class Clock:
    def __init__(self, step=1.0):
        self.now, self.step = 0.0, step

    def __call__(self):
        self.now += self.step
        return self.now


def native_image(path, architecture):
    return {"path": path, "architecture": "arm64x" if path.endswith("vcruntime140.dll") else "arm64", "native": True}


APP = "C:\\a\\SpeakWindows.exe"
SYSTEM = ["C:\\Windows\\System32\\ntdll.dll", "C:\\Windows\\System32\\KERNEL32.DLL"]


class ObservationTests(unittest.TestCase):
    def observe(self, api, process=None, timeout=60.0):
        return NATIVE.observe(process or FakeProcess(), api, clock=Clock(), sleep=lambda _: None, timeout=timeout)

    def test_native_arm64_process_passes_with_its_modules_recorded(self):
        api = FakeAPI(modules=[[APP] + SYSTEM, [APP] + SYSTEM + ["C:\\a\\swiftCore.dll", "C:\\a\\vcruntime140.dll"]])
        observation = self.observe(api)
        self.assertEqual(observation["processMachine"], ARM64)
        self.assertEqual(len(observation["modules"]), 5)
        self.assertEqual(api.closed, [("handle", 4242)])
        failures, images = NATIVE.assess_run(observation, "arm64", "C:\\Windows", native_image)
        self.assertEqual(failures, [])
        self.assertEqual([record["path"] for record in images],
                         [APP, "C:\\a\\swiftCore.dll", "C:\\a\\vcruntime140.dll"])

    def test_emulated_x64_process_on_an_arm64_host_fails(self):
        api = FakeAPI(machine=AMD64, modules=[[APP, "C:\\Windows\\System32\\xtajit64.dll"] + SYSTEM])
        failures, _ = NATIVE.assess_run(self.observe(api), "arm64", "C:\\Windows", native_image)
        self.assertIn("Windows reported a x64 process, not arm64", failures)
        self.assertTrue(any("emulation modules were loaded" in failure and "xtajit64.dll" in failure
                            for failure in failures))

    def test_foreign_modules_exit_codes_and_missing_evidence_fail(self):
        def reader(path, architecture):
            return {"path": path, "architecture": "x64" if "ggml" in path else "arm64", "native": "ggml" not in path}
        api = FakeAPI(modules=[[APP, "C:\\rt\\ggml-cpu.dll"] + SYSTEM])
        failures, _ = NATIVE.assess_run(self.observe(api, FakeProcess(exit_code=3)), "arm64", "C:\\Windows", reader)
        self.assertIn("exited with 3", failures)
        self.assertIn("loaded a x64 module: C:\\rt\\ggml-cpu.dll", failures)
        failures, _ = NATIVE.assess_run(self.observe(FakeAPI()), "arm64", "C:\\Windows", reader)
        self.assertIn("no loaded modules were observed", failures)

    def test_timeout_kills_the_process(self):
        process = FakeProcess(polls=1000)
        observation = self.observe(FakeAPI(modules=[[APP]]), process, timeout=3.0)
        self.assertTrue(process.killed)
        self.assertTrue(observation["timedOut"])
        failures, _ = NATIVE.assess_run(observation, "arm64", "C:\\Windows", native_image)
        self.assertIn("did not exit before its deadline", failures)

    def test_machine_is_only_inferred_without_process_machine_info_on_x64_hosts(self):
        x64 = FakeAPI(machine=None, native=AMD64, machine_error=True)
        self.assertEqual(NATIVE.query_machine(x64, "h"), (AMD64, None, AMD64))
        wow = FakeAPI(native=AMD64, wow64=PE.IMAGE_FILE_MACHINE_I386, machine_error=True)
        with self.assertRaises(OSError):
            NATIVE.query_machine(wow, "h")
        arm = FakeAPI(machine_error=True, modules=[[APP]])
        with self.assertRaises(OSError):
            NATIVE.query_machine(arm, "h")
        observation = self.observe(arm)
        self.assertIsNone(observation["processMachine"])
        self.assertTrue(observation["queryErrors"])
        failures, _ = NATIVE.assess_run(observation, "arm64", "C:\\Windows", native_image)
        self.assertIn("Windows reported a missing process, not arm64", failures)


class ImageAndHostTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = pathlib.Path(self.directory.name)

    def write(self, name, **options):
        path = self.root / name
        path.write_bytes(BUNDLE_TESTS.build_pe(["KERNEL32.dll"], **options))
        return path

    def test_images_must_run_natively_on_the_target(self):
        arm64 = self.write("SpeakWindows.exe", machine=ARM64)
        hybrid = self.write("msvcp140.dll", machine=ARM64, dll=True, hybrid_metadata=0x180105050)
        records = NATIVE.check_images([arm64, hybrid], "arm64")
        self.assertEqual([record["architecture"] for record in records], ["arm64", "arm64x"])
        self.assertEqual(records[0]["sha256"], NATIVE.sha256_file(arm64))
        for name, options in [("x64.exe", {}), ("ec.dll", {"dll": True, "hybrid_metadata": 0x18000A2E8})]:
            with self.assertRaisesRegex(NATIVE.ExecutionError, "not native arm64 images"):
                NATIVE.check_images([self.write(name, **options)], "arm64")
        with self.assertRaisesRegex(NATIVE.ExecutionError, "not native x64 images"):
            NATIVE.check_images([arm64], "x64")

    def test_host_must_be_native_for_the_target(self):
        toolchain = self.write("swift.exe", machine=ARM64)
        record = NATIVE.check_host(FakeAPI(), "arm64", [toolchain])
        self.assertEqual(record["nativeMachine"], "arm64")
        self.assertEqual(record["pythonProcessMachine"], "arm64")
        self.assertEqual(record["toolchain"][0]["architecture"], "arm64")
        with self.assertRaisesRegex(NATIVE.ExecutionError, "native machine is x64, not arm64"):
            NATIVE.check_host(FakeAPI(machine=AMD64, native=AMD64), "arm64")

    def test_run_requires_native_success_and_expected_output(self):
        executable = self.write("SpeakWindows.exe", machine=ARM64)
        stdout, stderr = self.root / "out.log", self.root / "err.log"

        def launch(arguments, stdout, stderr):
            self.assertEqual(arguments, [str(executable), "--self-test"])
            stdout.write(b"Windows native self-test passed\n")
            return FakeProcess()

        api = FakeAPI(modules=[[str(executable)] + SYSTEM])
        record = NATIVE.run([str(executable), "--self-test"], api, "arm64", "self-test", 30, stdout, stderr,
                            ["self-test passed"], "C:\\Windows", launch, native_image)
        self.assertEqual(record["failures"], [])
        self.assertEqual(record["processMachine"], "arm64")
        self.assertEqual(record["executable"]["architecture"], "arm64")
        record = NATIVE.run([str(executable), "--self-test"], FakeAPI(modules=[[str(executable)]]), "arm64",
                            "self-test", 30, stdout, stderr, ["window passed"], "C:\\Windows", launch, native_image)
        self.assertIn("output lacks 'window passed'", record["failures"])
        with self.assertRaisesRegex(NATIVE.ExecutionError, "not native arm64 images"):
            NATIVE.run([str(self.write("x64.exe"))], api, "arm64", "x", 30, stdout, stderr, (), "C:\\Windows",
                       launch, native_image)


class CommandLineTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = pathlib.Path(self.directory.name)
        self.evidence = self.root / "evidence.json"

    def test_image_evidence_accumulates_and_keeps_its_architecture(self):
        first, second = self.root / "a.exe", self.root / "b.dll"
        first.write_bytes(BUNDLE_TESTS.build_pe(machine=ARM64))
        second.write_bytes(BUNDLE_TESTS.build_pe(machine=ARM64, dll=True))
        with contextlib.redirect_stdout(io.StringIO()) as output:
            NATIVE.main(["--architecture", "arm64", "--evidence", str(self.evidence), "images", str(first)])
            NATIVE.main(["--architecture", "arm64", "--evidence", str(self.evidence), "images", str(second)])
        self.assertEqual(output.getvalue().splitlines(), ["1 native arm64 images"] * 2)
        evidence = json.loads(self.evidence.read_text(encoding="utf-8"))
        self.assertEqual([record["name"] for record in evidence["images"]], ["a.exe", "b.dll"])
        with self.assertRaisesRegex(NATIVE.ExecutionError, "records arm64, not x64"):
            NATIVE.main(["--architecture", "x64", "--evidence", str(self.evidence), "images", str(first)])

    def test_failures_still_write_evidence(self):
        foreign = self.root / "x64.exe"
        foreign.write_bytes(BUNDLE_TESTS.build_pe())
        with self.assertRaises(NATIVE.ExecutionError):
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
        with self.assertRaisesRegex(NATIVE.ExecutionError, "runs on Windows only"):
            NATIVE.main(["--architecture", "arm64", "--evidence", str(self.evidence), "host"])


if __name__ == "__main__":
    unittest.main()
