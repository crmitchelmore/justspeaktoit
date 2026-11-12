"""Shared fakes and module handles for the verify-native-execution.py tests.

The test_native_execution_*.py files import from here; it holds no tests itself.
"""
import base64
import json
import pathlib
import sys
import types

HERE = pathlib.Path(__file__).resolve().parent
sys.dont_write_bytecode = True
sys.path.insert(0, str(HERE))
import pe_test_fixtures as FIXTURES  # noqa: E402


def load(name, file_name):
    return FIXTURES.load_script(name, HERE / file_name)


NATIVE = load("verify_native_execution", "verify-native-execution.py")
import native_execution_debugger as DEBUGGER  # noqa: E402
import windows_pe as PE  # noqa: E402

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


class StandaloneRequests:
    """Standalone-diagnostic requests and a faked operation, shared by the diagnostic test classes."""
    def request(self, **changes):
        value = {"schema": 1, "architecture": "arm64", "label": "ui-smoke", "arguments": ["--ui-smoke-test"],
                 "exitCode": -1073740940, "originalPid": 321, "startedUTC": "2026-10-28T12:00:00+00:00",
                 "endedUTC": "2026-10-28T12:00:03+00:00", "executable": r"C:\Owned κόσμε\SpeakWindows.exe",
                 "expectedSHA256": "a" * 64, "powershell": r"C:\Owned\pwsh.exe", "powershellSHA256": "b" * 64,
                 "parentPid": 123, "deadlineTicks": 30000, "frequency": 1000}
        value.update(changes)
        return value

    def encode(self, value):
        return base64.urlsafe_b64encode(json.dumps(value).encode()).decode().rstrip("=")

    def api(self, **changes):
        values = dict(frequency=lambda: 1000, ticks=lambda: 10000, admitted=lambda request: True)
        values.update(changes)
        return types.SimpleNamespace(**values)

    def fixture(self):
        # Deliberately private paths, symbols and absolute PCs must never escape.
        return (b"C:\\private-canary\\secret.pdb\nJSTI_DIAG_READY\nJSTI_DIAG_FAULT 0xc0000374\n"
                b"JSTI_DIAG_IP 00000001`00000042\nJSTI_DIAG_MODULES\n"
                b"00000001`00000000 00000001`00001000 SpeakWindows (export symbols) C:\\private-canary\n"
                b"00000002`00000000 00000002`00001000 private_module (deferred)\n"
                b"JSTI_DIAG_STACK\n00 00000003`00000000 00000002`00000024 SpeakWindows!private_function+0xbad\n"
                b"01 00000003`00000080 00000000`00000000 private_module!private_function+0xfeed\nJSTI_DIAG_END\n")

    def operate(self, value=None, api=None, identity=None, runner=None):
        identity = identity or (lambda path, *args, **kwargs: (path, "same-snapshot"))
        runner = runner or (lambda *args, **kwargs: {"status": "complete", "cleanup": "clean", "exitCode": 0,
                                                   "output": self.fixture() if args[0][0] == DEBUGGER.CDB_LOCATION
                                                   else b'{"status":"unavailable"}'})
        return DEBUGGER.standalone_diagnostic(self.encode(value or self.request()), lambda: api or self.api(), identity, runner)
