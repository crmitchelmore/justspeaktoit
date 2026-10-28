#!/usr/bin/env python3
"""Prove that Windows binaries run natively for their architecture, not under emulation.

Windows 11 on ARM runs x64 programs through emulation, so a green test run on
an ARM64 runner says nothing about ARM64 by itself: an x64 toolchain would
build x64 binaries that pass there too. This helper records three kinds of
evidence in one JSON file:

``host``    the operating system's native machine (IsWow64Process2), which
            must be the target architecture, and the images of the toolchain;
``images``  every named PE file must be an image a native process of the
            architecture loads (x64: x64; ARM64: ARM64 or ARM64X, never x64
            or ARM64EC), checked from the file headers;
``run``     starts a program, reads the machine Windows reports for the new
            process (GetProcessInformation(ProcessMachineTypeInfo)), samples
            its loaded modules until it exits, and requires the target
            machine, no emulator module, native images for every module
            outside %SystemRoot%, exit code 0 and any expected output.

An ARM64 image cannot be emulated on Windows, so native ``images`` on a native
``host`` already exclude x64 emulation; ``run`` observes it directly.
"""
import argparse
import base64
import datetime
import hashlib
import json
import ntpath
import os
import pathlib
import platform
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time

HERE = pathlib.Path(__file__).resolve().parent
sys.dont_write_bytecode = True
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))
import windows_pe  # noqa: E402
import windows_targets  # noqa: E402

MACHINE_NAMES = {0: "unknown", windows_pe.IMAGE_FILE_MACHINE_I386: "x86", windows_pe.IMAGE_FILE_MACHINE_AMD64: "x64",
                 windows_pe.IMAGE_FILE_MACHINE_ARM64: "arm64", 0x01C4: "arm"}
# Loaded only into emulated (x64 or ARM64EC) and WOW64 processes.
EMULATION_MODULES = {"xtajit.dll", "xtajit64.dll", "xtajit64se.dll", "xtabase.dll", "wow64.dll", "wow64base.dll",
                     "wow64con.dll", "wow64cpu.dll", "wow64win.dll", "wowarmhw.dll"}


class ExecutionError(Exception):
    """The evidence does not show native execution."""


def machine_name(value):
    return MACHINE_NAMES.get(value, "machine-%#06x" % value)


def sha256_file(path):
    hasher = hashlib.sha256()
    with pathlib.Path(path).open("rb") as stream:
        while chunk := stream.read(1 << 20):
            hasher.update(chunk)
    return hasher.hexdigest()


def describe_image(path, architecture):
    """Header facts of one PE file and whether a native ``architecture`` process loads it."""
    path = pathlib.Path(path)
    image = windows_pe.PEImage.load(path)
    return {"path": str(path), "name": path.name, "bytes": path.stat().st_size, "sha256": sha256_file(path),
            "architecture": image.architecture, "dll": image.is_dll, "subsystem": image.subsystem,
            "native": image.runs_natively_on(architecture)}


# --- Windows process inspection ------------------------------------------------------
class WindowsAPI:
    """The kernel32 calls the checks need, loaded only on Windows."""
    PROCESS_QUERY_INFORMATION = 0x0400
    PROCESS_VM_READ = 0x0010
    PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
    PROCESS_MACHINE_TYPE_INFO = 9  # PROCESS_INFORMATION_CLASS.ProcessMachineTypeInfo
    LIST_MODULES_ALL = 3

    def __init__(self):
        import ctypes
        from ctypes import wintypes
        self.ctypes, self.wintypes = ctypes, wintypes
        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        self.kernel32 = kernel32
        kernel32.OpenProcess.restype = wintypes.HANDLE
        kernel32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
        kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
        kernel32.GetCurrentProcess.restype = wintypes.HANDLE
        kernel32.IsWow64Process2.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.USHORT),
                                             ctypes.POINTER(wintypes.USHORT)]
        kernel32.GetProcessInformation.argtypes = [wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD]
        kernel32.K32EnumProcessModulesEx.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.HMODULE),
                                                     wintypes.DWORD, ctypes.POINTER(wintypes.DWORD), wintypes.DWORD]
        kernel32.K32GetModuleFileNameExW.argtypes = [wintypes.HANDLE, wintypes.HMODULE, wintypes.LPWSTR,
                                                     wintypes.DWORD]

    def open(self, pid):
        access = self.PROCESS_QUERY_INFORMATION | self.PROCESS_VM_READ
        handle = self.kernel32.OpenProcess(access, False, pid)
        if not handle:
            handle = self.kernel32.OpenProcess(self.PROCESS_QUERY_LIMITED_INFORMATION, False, pid)
        if not handle:
            raise OSError(self.ctypes.get_last_error(), "OpenProcess failed")
        return handle

    def close(self, handle):
        self.kernel32.CloseHandle(handle)

    def current(self):
        return self.kernel32.GetCurrentProcess()

    def wow64(self, handle):
        """``(process machine, native machine)``; the first is 0 unless the process runs under WOW64."""
        process, native = self.wintypes.USHORT(), self.wintypes.USHORT()
        if not self.kernel32.IsWow64Process2(handle, self.ctypes.byref(process), self.ctypes.byref(native)):
            raise OSError(self.ctypes.get_last_error(), "IsWow64Process2 failed")
        return process.value, native.value

    def process_machine(self, handle):
        """``(machine, attributes)`` Windows reports for the process (Windows 11 and later)."""
        buffer = (self.ctypes.c_ubyte * 8)()
        if not self.kernel32.GetProcessInformation(handle, self.PROCESS_MACHINE_TYPE_INFO, buffer, 8):
            raise OSError(self.ctypes.get_last_error(), "GetProcessInformation(ProcessMachineTypeInfo) failed")
        raw = bytes(buffer)
        return int.from_bytes(raw[0:2], "little"), int.from_bytes(raw[4:8], "little")

    def modules(self, handle, known):
        """Paths of the process's loaded modules; empty while the loader is not ready.

        ``known`` maps module handles to paths already read, so repeated samples
        of a long-running process only resolve newly loaded modules.
        """
        needed = self.wintypes.DWORD()
        capacity = 1024
        array = (self.wintypes.HMODULE * capacity)()
        if not self.kernel32.K32EnumProcessModulesEx(handle, array, self.ctypes.sizeof(array),
                                                     self.ctypes.byref(needed), self.LIST_MODULES_ALL):
            return []
        count = min(capacity, needed.value // self.ctypes.sizeof(self.wintypes.HMODULE))
        buffer = self.ctypes.create_unicode_buffer(32768)
        paths = []
        for index in range(count):
            module = array[index]
            if module not in known and self.kernel32.K32GetModuleFileNameExW(handle, module, buffer, len(buffer)):
                known[module] = buffer.value
            if module in known:
                paths.append(known[module])
        return paths


# --- evidence ----------------------------------------------------------------------------
def load_evidence(path, architecture):
    path = pathlib.Path(path)
    if path.exists():
        evidence = json.loads(path.read_text(encoding="utf-8"))
        if evidence.get("architecture") != architecture:
            raise ExecutionError("evidence file records %s, not %s" % (evidence.get("architecture"), architecture))
        return evidence
    return {"schemaVersion": 1, "architecture": architecture, "host": None, "images": [], "runs": []}


def save_evidence(path, evidence):
    path = pathlib.Path(path)
    temporary = path.with_name(path.name + ".partial")
    temporary.write_text(json.dumps(evidence, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(temporary, path)


# Fixed local SDK/system candidates only: no PATH search, registry or directory scan.
DIAGNOSTIC_CANDIDATES = tuple(
    ("sdk10-%s-%s" % (arch, tool), r"C:\Program Files (x86)\Windows Kits\10\Debuggers" +
     "\\" + arch + "\\" + tool + ".exe")
    for arch in ("arm64", "x64", "x86") for tool in ("gflags", "cdb", "windbg")
) + (("system32-appverif", r"C:\Windows\System32\appverif.exe"),
     ("syswow64-appverif", r"C:\Windows\SysWOW64\appverif.exe"))
DIAGNOSTIC_FILE_LIMIT = 32 * 1024 * 1024
DIAGNOSTIC_TOTAL_LIMIT = 64 * 1024 * 1024


def numeric_file_version(path):
    """Read numeric VS_FIXEDFILEINFO only; never load/execute the candidate image."""
    if os.name != "nt":
        return None
    import ctypes
    from ctypes import wintypes
    api = ctypes.WinDLL("version.dll", winmode=0x800)  # LOAD_LIBRARY_SEARCH_SYSTEM32
    api.GetFileVersionInfoSizeW.argtypes = [wintypes.LPCWSTR, ctypes.POINTER(wintypes.DWORD)]
    api.GetFileVersionInfoSizeW.restype = wintypes.DWORD
    api.GetFileVersionInfoW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, ctypes.c_void_p]
    api.GetFileVersionInfoW.restype = wintypes.BOOL
    api.VerQueryValueW.argtypes = [ctypes.c_void_p, wintypes.LPCWSTR,
                                  ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(wintypes.UINT)]
    api.VerQueryValueW.restype = wintypes.BOOL
    size = api.GetFileVersionInfoSizeW(str(path), None)
    if not 0 < size <= 65536:
        return None
    buffer = ctypes.create_string_buffer(size)
    if not api.GetFileVersionInfoW(str(path), 0, size, buffer):
        return None
    address, length = ctypes.c_void_p(), wintypes.UINT()
    if not api.VerQueryValueW(buffer, "\\", ctypes.byref(address), ctypes.byref(length)):
        return None
    # VS_FIXEDFILEINFO is thirteen DWORDs. Validate the returned in-buffer view.
    byte_count = 13 * ctypes.sizeof(wintypes.DWORD)
    if length.value < byte_count or not address.value or not (
            ctypes.addressof(buffer) <= address.value <= ctypes.addressof(buffer) + size - byte_count):
        return None
    values = (wintypes.DWORD * 13).from_address(address.value)
    if values[0] != 0xFEEF04BD:
        return None
    return [values[2] >> 16, values[2] & 65535, values[3] >> 16, values[3] & 65535]


def diagnostic_tools(read_version=numeric_file_version, clock=time.monotonic):
    """Optional fixed-path metadata; absence never asserts global tool absence."""
    if os.name != "nt":
        return {"status": "unsupported", "tools": []}
    rows, remaining, started = [], DIAGNOSTIC_TOTAL_LIMIT, clock()
    for candidate, location in DIAGNOSTIC_CANDIDATES:
        row = {"candidate": candidate, "status": "unknown", "present": None}
        rows.append(row)
        if clock() - started > 3 or remaining <= 0:
            continue
        try:
            path = pathlib.Path(location)
            before = path.lstat()
            if not stat.S_ISREG(before.st_mode) or getattr(before, "st_file_attributes", 0) & 0x400:
                continue  # No reparse-point/alias candidates or directory traversal.
            row["present"] = True
            limit = min(DIAGNOSTIC_FILE_LIMIT, remaining)
            if not 0 < before.st_size <= limit:
                continue
            with path.open("rb") as stream:
                requested = min(before.st_size + 1, limit)
                remaining -= requested  # Failed reads may have consumed bytes; retain their reservation.
                data = stream.read(requested)
                remaining = max(0, remaining + requested - len(data))
                after = os.fstat(stream.fileno())
            if len(data) != before.st_size or (before.st_ino, before.st_mtime_ns, before.st_size) != (
                    after.st_ino, after.st_mtime_ns, after.st_size):
                continue
            row.update(status="present", bytes=len(data), sha256=hashlib.sha256(data).hexdigest(),
                       architecture="unknown", version=None)
            try:
                image = windows_pe.PEImage(data, "diagnostic-tool")
                if image.architecture in ("x86", "x64", "arm", "arm64", "arm64ec", "arm64x"):
                    row["architecture"] = image.architecture
            except (windows_pe.PEFormatError, ValueError):
                pass
            try:
                version = read_version(path)
                if isinstance(version, (list, tuple)) and len(version) == 4 and all(
                        type(v) is int and 0 <= v <= 65535 for v in version):
                    row["version"] = list(version)
            except Exception:
                pass  # No version/error strings are evidence.
            final = path.stat()
            if (after.st_ino, after.st_mtime_ns, after.st_size) != (
                    final.st_ino, final.st_mtime_ns, final.st_size):
                row.clear()
                row.update(candidate=candidate, status="unknown", present=None)
        except (FileNotFoundError, PermissionError) as error:
            row.clear()
            row.update(candidate=candidate, status="absent" if isinstance(error, FileNotFoundError) else "denied",
                       present=False if isinstance(error, FileNotFoundError) else None)
        except Exception:
            row.clear()
            row.update(candidate=candidate, status="unknown", present=None)
    return {"status": "inspected", "coverage": "fixed-sdk10-system-candidates-only", "tools": rows}


def check_host(api, architecture, toolchain=()):
    """The OS must be native ``architecture``; toolchain images are recorded, not required."""
    expected = windows_targets.target(architecture)["processMachine"]
    handle = api.current()
    try:
        python_machine, _, native = query_machine(api, handle)
    except OSError:
        python_machine, native = None, api.wow64(handle)[1]
    record = {"nativeMachine": machine_name(native), "pythonProcessMachine":
              None if python_machine is None else machine_name(python_machine),
              "platform": platform.platform(), "processorArchitecture": os.environ.get("PROCESSOR_ARCHITECTURE"),
              "processorIdentifier": os.environ.get("PROCESSOR_IDENTIFIER"),
              "toolchain": [describe_image(path, architecture) for path in toolchain]}
    if native != expected:
        raise ExecutionError("the host's native machine is %s, not %s" % (machine_name(native), machine_name(expected)))
    try:
        record["diagnosticTools"] = diagnostic_tools()
    except Exception:
        record["diagnosticTools"] = {"status": "unavailable", "tools": []}
    return record


def check_images(paths, architecture):
    records = [describe_image(path, architecture) for path in paths]
    foreign = ["%s (%s)" % (record["path"], record["architecture"]) for record in records if not record["native"]]
    if foreign:
        raise ExecutionError("not native %s images: %s" % (architecture, "; ".join(foreign)))
    return records


def query_machine(api, handle):
    """``(process machine, attributes, native machine)`` for a process handle.

    Without ProcessMachineTypeInfo (before Windows 11) only an x64 host can
    still answer: a process there that is not under WOW64 is native x64. On an
    ARM64 host the same answer could be an emulated x64 process, so it stays unknown.
    """
    wow64, native = api.wow64(handle)
    try:
        machine, attributes = api.process_machine(handle)
    except OSError:
        if wow64 or native != windows_pe.IMAGE_FILE_MACHINE_AMD64:
            raise
        machine, attributes = native, None
    return machine, attributes, native


def observe(process, api, clock=time.monotonic, sleep=time.sleep, timeout=60.0, interval=0.05, attempts=20):
    """Sample ``process`` (a Popen-like object) until it exits or ``timeout`` elapses."""
    started = clock()
    handle = api.open(process.pid)
    machine = attributes = native = None
    errors, modules, known, timed_out = [], {}, {}, False
    try:
        while True:
            if machine is None and len(errors) < attempts:
                try:
                    machine, attributes, native = query_machine(api, handle)
                except OSError as error:
                    errors.append(str(error))
            for path in api.modules(handle, known):
                modules.setdefault(path.lower(), path)
            if process.poll() is not None:
                break
            if clock() - started > timeout:
                timed_out = True
                process.kill()
                process.wait()
                break
            sleep(interval)
        if machine is None:
            # A process that exited before its first sample still has a queryable object.
            try:
                machine, attributes, native = query_machine(api, handle)
            except OSError as error:
                errors.append(str(error))
    finally:
        api.close(handle)
    return {"processMachine": machine, "machineAttributes": attributes, "nativeMachine": native,
            "modules": sorted(modules.values(), key=str.lower), "timedOut": timed_out,
            "exitCode": process.returncode, "seconds": round(clock() - started, 3), "queryErrors": errors[:3]}


def assess_run(observation, architecture, system_root, read_image=describe_image):
    """Failures in an observed run, and the module facts recorded as evidence."""
    target = windows_targets.target(architecture)
    failures = []
    if observation["timedOut"]:
        failures.append("did not exit before its deadline")
    elif observation["exitCode"] != 0:
        failures.append("exited with %s" % observation["exitCode"])
    if observation["processMachine"] != target["processMachine"]:
        failures.append("Windows reported a %s process, not %s" % (
            "missing" if observation["processMachine"] is None else machine_name(observation["processMachine"]),
            machine_name(target["processMachine"])))
    if observation["nativeMachine"] not in (None, target["processMachine"]):
        failures.append("the native machine is %s" % machine_name(observation["nativeMachine"]))
    emulation = [path for path in observation["modules"] if pathlib.PureWindowsPath(path).name.lower() in EMULATION_MODULES]
    if emulation:
        failures.append("emulation modules were loaded: " + ", ".join(emulation))
    if not observation["modules"]:
        failures.append("no loaded modules were observed")
    root = system_root.rstrip("\\").lower() + "\\"
    images = []
    for path in observation["modules"]:
        if path.lower().startswith(root):
            continue
        try:
            record = read_image(path, architecture)
        except (OSError, windows_pe.PEFormatError) as error:
            failures.append("cannot read loaded module %s: %s" % (path, error))
            continue
        images.append(record)
        if not record["native"]:
            failures.append("loaded a %s module: %s" % (record["architecture"], path))
    return failures, images


# Read only named crash fields; never render Message, complete XML or an error.
APPLICATION_ERROR_QUERY = r"""
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
try {
    $events = @(Get-WinEvent -FilterHashtable @{
        LogName='Application'; ProviderName='Application Error'; Id=1000
        StartTime=[DateTime]::Parse($env:JSTI_EVENT_START).ToUniversalTime()
        EndTime=[DateTime]::Parse($env:JSTI_EVENT_END).ToUniversalTime()
    } -MaxEvents 16 -ErrorAction Stop)
    $rows = @()
    foreach ($event in $events) {
        [xml]$xml = $event.ToXml()
        $data = @{}
        foreach ($entry in $xml.Event.EventData.Data) {
            if ($entry.Name -cin @('AppName','AppPath','ProcessId','FaultingProcessId',
                                  'ModuleName','ModuleVersion','ExceptionCode','FaultingOffset')) {
                if ($data.ContainsKey([string]$entry.Name) -or ([string]$entry.InnerText).Length -gt 4096) {
                    throw 'Invalid crash field'
                }
                $data[[string]$entry.Name] = [string]$entry.InnerText
            }
        }
        $rows += @{time=$event.TimeCreated.ToUniversalTime().ToString('o'); data=$data}
    }
    @{status='ok'; events=@($rows)} | ConvertTo-Json -Depth 4 -Compress
} catch {
    @{status='unavailable'} | ConvertTo-Json -Compress
}
"""


def project_application_error(events, pid, executable, started, ended):
    """Project one exact owned crash; private path/identity fields never escape."""
    if not isinstance(events, list) or len(events) > 16:
        return {"status": "invalid"}
    matches = []
    fields = {"AppName", "AppPath", "ProcessId", "FaultingProcessId", "ModuleName", "ModuleVersion",
              "ExceptionCode", "FaultingOffset"}
    for event in events:
        if not isinstance(event, dict) or set(event) != {"time", "data"} or not isinstance(event["data"], dict):
            return {"status": "invalid"}
        data = event["data"]
        if set(data) - fields or any(not isinstance(v, str) or len(v) > 4096 for v in data.values()):
            return {"status": "invalid"}
        if data.get("AppName", "").casefold() != ntpath.basename(executable).casefold():
            continue
        process_ids = [data[key] for key in ("ProcessId", "FaultingProcessId") if key in data]
        if not process_ids or any(not re.fullmatch(r"(?:0x[0-9a-fA-F]{1,16}|[0-9]{1,20})", v)
                                  for v in process_ids):
            return {"status": "invalid"}
        if len({int(v, 16 if v.startswith("0x") else 10) for v in process_ids}) != 1:
            return {"status": "invalid"}
        if int(process_ids[0], 16 if process_ids[0].startswith("0x") else 10) != pid:
            continue
        if not ntpath.isabs(data.get("AppPath", "")):
            return {"status": "invalid"}
        if ntpath.normcase(ntpath.normpath(data["AppPath"])) != ntpath.normcase(ntpath.normpath(executable)):
            continue
        if not isinstance(event["time"], str) or len(event["time"]) > 40:
            return {"status": "invalid"}
        try:
            moment = datetime.datetime.fromisoformat(event["time"].replace("Z", "+00:00"))
        except ValueError:
            return {"status": "invalid"}
        if moment.tzinfo is None:
            return {"status": "invalid"}
        if not started <= moment <= ended:
            continue
        patterns = {"ModuleName": r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}",
                    "ModuleVersion": r"[0-9]{1,10}(?:\.[0-9]{1,10}){0,3}",
                    "ExceptionCode": r"(?:0x)?[0-9a-fA-F]{8}",
                    "FaultingOffset": r"(?:0x)?[0-9a-fA-F]{1,16}"}
        if any(not re.fullmatch(pattern, data.get(key, "")) for key, pattern in patterns.items()):
            return {"status": "invalid"}
        matches.append({"module": data["ModuleName"], "version": data["ModuleVersion"],
                        "exceptionCode": "0x%08x" % int(data["ExceptionCode"], 16),
                        "faultOffset": "0x%016x" % int(data["FaultingOffset"], 16),
                        "timeUTC": moment.astimezone(datetime.timezone.utc).isoformat()})
    if len(matches) != 1:
        return {"status": "ambiguous" if matches else "no-match"}
    return {"status": "observed", **matches[0]}


def application_error(pid, executable, started, ended, query=subprocess.run):
    """Optional five-second query; collector failures cannot replace runtime evidence."""
    try:
        environment = {key: os.environ[key] for key in ("PATH", "SystemRoot", "WINDIR", "TEMP", "TMP")
                       if key in os.environ}
        environment.update(JSTI_EVENT_START=started.isoformat(), JSTI_EVENT_END=ended.isoformat())
        result = query(["pwsh", "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", APPLICATION_ERROR_QUERY],
                       stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                       env=environment, timeout=5, check=False)
        if result.returncode != 0:
            return {"status": "unavailable"}
        if len(result.stdout) > 65536:
            return {"status": "invalid"}
        payload = json.loads(result.stdout.decode("utf-8-sig"))
        if payload == {"status": "unavailable"}:
            return payload
        if not isinstance(payload, dict) or set(payload) != {"status", "events"} or payload["status"] != "ok":
            return {"status": "invalid"}
        return project_application_error(payload["events"], pid, executable, started, ended)
    except subprocess.TimeoutExpired:
        return {"status": "timeout"}
    except Exception:
        # Neither exception text nor captured output is safe diagnostic content.
        return {"status": "unavailable"}


class NativeOwnerDeadline:
    """Trusted PS caller's existing original-process QPC deadline; never launches a diagnostic."""
    def __init__(self, ticks, frequency, api):
        if any(type(value) is not int or not 0 < value <= 0x7fffffffffffffff for value in (ticks, frequency)):
            raise ExecutionError("invalid diagnostic deadline")
        self.end, self.frequency, self.api = ticks, frequency, api
        if api.frequency() != frequency or not 0 < self.remaining() <= 30:
            raise ExecutionError("invalid diagnostic deadline")

    def remaining(self):
        return max(0.0, (self.end - self.api.ticks()) / self.frequency)


def normalize_native_crash(code):
    """Only the three admitted signed/UINT32 spellings; never truncate arbitrary integers."""
    if type(code) is not int:
        return None
    for signed in CRASH_CODES:
        if code in (signed, signed + 0x100000000):
            return signed
    return None


def native_owner_context(process, observation, started, ended, deadline):
    code = normalize_native_crash(observation["exitCode"])
    if (code is None or observation["timedOut"] or observation["processMachine"] != 0xaa64 or
            observation["nativeMachine"] != 0xaa64 or type(process.pid) is not int or
            not 0 < process.pid <= 0xffffffff or not 0 <= (ended - started).total_seconds() <= 30):
        return None
    return {"schema": 1, "originalPid": process.pid, "startedUTC": started.isoformat(),
            "endedUTC": ended.isoformat(), "deadlineTicks": deadline.end,
            "frequency": deadline.frequency, "exitCode": code}


def run(arguments, api, architecture, label, timeout, stdout_path, stderr_path, expected_output=(),
        system_root=None, launch=subprocess.Popen, read_image=describe_image, event_reader=application_error, *,
        diagnostic_owner_context=False, deadline_ticks=None, deadline_frequency=None, deadline_api_factory=None):
    """Run ``arguments`` and return its evidence record; ``failures`` lists what was not native or successful.

    A program that is not a native image is refused before it starts.
    """
    executable = shutil.which(arguments[0]) or arguments[0]
    main_image = check_images([executable], architecture)[0]
    crash_candidate = (os.name == "nt" and label == "ui-smoke-test" and arguments[1:] == ["--ui-smoke-test"]
                       and ntpath.basename(executable).casefold() == "speakwindows.exe")
    deadline = None
    if diagnostic_owner_context:
        if not crash_candidate or architecture != "arm64" or not 0 < timeout <= 30:
            raise ExecutionError("diagnostic owner context requires the native ARM64 UI smoke command")
        try:
            deadline = NativeOwnerDeadline(deadline_ticks, deadline_frequency,
                                           (deadline_api_factory or StandaloneWindows)())
        except (OSError, ValueError, TypeError):
            raise ExecutionError("diagnostic clock unavailable") from None
    elif deadline_ticks is not None or deadline_frequency is not None:
        raise ExecutionError("diagnostic deadline requires owner context")
    started = datetime.datetime.now(datetime.timezone.utc) if crash_candidate else None
    with open(stdout_path, "wb") as stdout, open(stderr_path, "wb") as stderr:
        process = launch([executable] + list(arguments[1:]), stdout=stdout, stderr=stderr)
        # Re-sample AFTER Popen: executable validation/launch time consumes the
        # same caller deadline. A clock failure cannot leave a fresh child unobserved.
        remaining, deadline_clock_valid = timeout, True
        if deadline is not None:
            try:
                remaining = min(timeout, deadline.remaining())
            except OSError:
                remaining, deadline_clock_valid = 0, False
        observation = observe(process, api, timeout=remaining)
    ended = datetime.datetime.now(datetime.timezone.utc) if crash_candidate else None
    system_root = system_root or os.environ.get("SystemRoot", r"C:\Windows")
    failures, images = assess_run(observation, architecture, system_root, read_image)
    output = pathlib.Path(stdout_path).read_bytes() + pathlib.Path(stderr_path).read_bytes()
    for text in expected_output:
        if text.encode("utf-8") not in output:
            failures.append("output lacks %r" % text)
    record = {"label": label, "arguments": [str(value) for value in arguments[1:]], "executable": main_image,
              "processMachine": None if observation["processMachine"] is None else machine_name(observation["processMachine"]),
              "machineAttributes": observation["machineAttributes"],
              "nativeMachine": None if observation["nativeMachine"] is None else machine_name(observation["nativeMachine"]),
              "exitCode": observation["exitCode"], "timedOut": observation["timedOut"], "seconds": observation["seconds"],
              "modulesObserved": len(observation["modules"]), "modulesOutsideSystemRoot": images,
              "queryErrors": observation["queryErrors"], "failures": failures}
    if deadline is not None and deadline_clock_valid:
        context = native_owner_context(process, observation, started, ended, deadline)
        if context is not None:
            record["diagnosticOwnerContext"] = context
    if deadline is None and crash_candidate and observation["exitCode"] not in (None, 0) and not observation["timedOut"]:
        try:
            record["applicationError"] = event_reader(process.pid, os.path.abspath(executable), started,
                                                      datetime.datetime.now(datetime.timezone.utc))
        except Exception:
            record["applicationError"] = {"status": "unavailable"}
    return record


# --- Private failure-only standalone diagnostic -------------------------------------
# This is not an authenticated service or a qualification retry. The trusted PS
# caller owns the exact unnamed JOB_LIST job before this bridge can execute.
STANDALONE_KEYS = {"schema", "architecture", "label", "arguments", "exitCode", "originalPid", "startedUTC",
                   "endedUTC", "executable", "expectedSHA256", "powershell", "powershellSHA256", "parentPid",
                   "deadlineTicks", "frequency"}
CRASH_CODES = {-1073741819: "0xc0000005", -1073740940: "0xc0000374", -1073740791: "0xc0000409"}
CDB_LOCATION = r"C:\Program Files (x86)\Windows Kits\10\Debuggers\arm64\cdb.exe"
CDB_SHA256 = "efda8a8d73116ba97189e1bc638d888f41b592fcc1ba11d8a9039ff2a2472a75"
CDB_VERSION = [10, 0, 26100, 6584]
DIAGNOSTIC_MODULES = {"speakwindows": "app", "ntdll": "ntdll", "kernel32": "kernel32", "kernelbase": "kernelbase",
                      "ucrtbase": "ucrtbase", "swiftcore": "swiftCore", "swift_concurrency": "swift_Concurrency",
                      "swiftdispatch": "swiftDispatch"}
STANDALONE_STATUSES = {"unavailable", "deadline", "observed", "no-reproduction", "invalid", "truncated"}


def closed_module(name):
    return DIAGNOSTIC_MODULES.get(ntpath.splitext(ntpath.basename(name))[0].casefold(), "unknown")


def diagnostic_result(status="unavailable", cleanup="not-started"):
    return {"schema": 1, "status": status, "cleanup": cleanup, "applicationError": {"status": "unavailable"},
            "debugger": {"status": status, "exceptionCode": None, "frames": []}}


def unique_json(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError("duplicate field")
        value[key] = item
    return value


def diagnostic_request(encoded):
    """Decode the exact internal request. Never format a supplied field/error."""
    if not isinstance(encoded, str) or not 0 < len(encoded) <= 10924 or not re.fullmatch(r"[A-Za-z0-9_-]+", encoded):
        raise ValueError("invalid request")
    raw = base64.b64decode(encoded + "=" * (-len(encoded) % 4), altchars=b"-_", validate=True)
    if len(raw) > 8192:
        raise ValueError("invalid request")
    value = json.loads(raw.decode("utf-8"), object_pairs_hook=unique_json)
    if not isinstance(value, dict) or set(value) not in (STANDALONE_KEYS, STANDALONE_KEYS | {"runtimeModules"}):
        raise ValueError("invalid request")
    if type(value["schema"]) is not int or value["schema"] != 1 or value["architecture"] != "arm64" or \
            value["label"] != "ui-smoke" or value["arguments"] != ["--ui-smoke-test"] or \
            type(value["exitCode"]) is not int or value["exitCode"] not in CRASH_CODES:
        raise ValueError("invalid request")
    for key in ("originalPid", "parentPid", "deadlineTicks", "frequency"):
        if type(value[key]) is not int or not 0 < value[key] < (1 << (32 if key.endswith("Pid") else 63)):
            raise ValueError("invalid request")
    for key in ("expectedSHA256", "powershellSHA256"):
        if not isinstance(value[key], str) or not re.fullmatch(r"[0-9a-f]{64}", value[key]):
            raise ValueError("invalid request")
    for key, names in (("executable", {"speakwindows.exe"}), ("powershell", {"pwsh.exe", "powershell.exe"})):
        text = value[key]
        if not isinstance(text, str) or len(text) > 4096 or not re.match(r"^[A-Za-z]:\\", text) or \
                any(ord(c) < 32 for c in text) or '"' in text or ":" in text[2:] or \
                ntpath.basename(text).casefold() not in names or ntpath.normpath(text) != text:
            raise ValueError("invalid request")
    for key in ("startedUTC", "endedUTC"):
        if not isinstance(value[key], str) or len(value[key]) > 40:
            raise ValueError("invalid request")
        moment = datetime.datetime.fromisoformat(value[key].replace("Z", "+00:00"))
        if moment.tzinfo is None or moment.utcoffset() != datetime.timedelta(0):
            raise ValueError("invalid request")
    start = datetime.datetime.fromisoformat(value["startedUTC"].replace("Z", "+00:00"))
    end = datetime.datetime.fromisoformat(value["endedUTC"].replace("Z", "+00:00"))
    if not 0 <= (end - start).total_seconds() <= 30:
        raise ValueError("invalid request")
    if "runtimeModules" in value:
        diagnostic_runtime_request(value["runtimeModules"])
    return value


class StandaloneWindows:
    """Small read-only job/QPC checks; parent alone owns/terminates the job."""
    def __init__(self):
        if os.name != "nt":
            raise OSError("unsupported")
        import ctypes
        self.ctypes = ctypes
        api = ctypes.WinDLL("kernel32", use_last_error=True, winmode=0x800)
        self.api = api
        api.GetCurrentProcess.restype = ctypes.c_void_p
        api.IsProcessInJob.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.POINTER(ctypes.c_int32)]
        api.IsProcessInJob.restype = ctypes.c_int32
        api.QueryInformationJobObject.argtypes = [ctypes.c_void_p, ctypes.c_int32, ctypes.c_void_p,
                                                  ctypes.c_uint32, ctypes.POINTER(ctypes.c_uint32)]
        api.QueryInformationJobObject.restype = ctypes.c_int32
        api.QueryPerformanceCounter.argtypes = [ctypes.POINTER(ctypes.c_int64)]
        api.QueryPerformanceCounter.restype = ctypes.c_int32
        api.QueryPerformanceFrequency.argtypes = [ctypes.POINTER(ctypes.c_int64)]
        api.QueryPerformanceFrequency.restype = ctypes.c_int32

    def frequency(self):
        value = self.ctypes.c_int64()
        if not self.api.QueryPerformanceFrequency(self.ctypes.byref(value)):
            raise OSError("clock unavailable")
        return value.value

    def ticks(self):
        value = self.ctypes.c_int64()
        if not self.api.QueryPerformanceCounter(self.ctypes.byref(value)):
            raise OSError("clock unavailable")
        return value.value

    def admitted(self, request):
        c = self.ctypes
        # Explicit fixed-width DWORD/LARGE_INTEGER and pointer-sized SIZE_T.
        class Basic(c.Structure):
            _fields_ = [("processTime", c.c_int64), ("jobTime", c.c_int64), ("flags", c.c_uint32),
                        ("minimum", c.c_size_t), ("maximum", c.c_size_t), ("active", c.c_uint32),
                        ("affinity", c.c_size_t), ("priority", c.c_uint32), ("scheduling", c.c_uint32)]
        class Extended(c.Structure):
            _fields_ = [("basic", Basic), ("io", c.c_uint64 * 6), ("processMemory", c.c_size_t),
                        ("jobMemory", c.c_size_t), ("peakProcess", c.c_size_t), ("peakJob", c.c_size_t)]
        member, limits, size = c.c_int32(), Extended(), c.c_uint32()
        return (request["parentPid"] == os.getppid() and
                self.api.IsProcessInJob(self.api.GetCurrentProcess(), None, c.byref(member)) != 0 and member.value == 1 and
                self.api.QueryInformationJobObject(None, 9, c.byref(limits), c.sizeof(limits), c.byref(size)) != 0 and
                size.value == c.sizeof(limits) and limits.basic.flags == 0x2000)  # KILL_ON_JOB_CLOSE only.


class DiagnosticBudget:
    def __init__(self, request, api):
        # Parent supplies its original-deadline-minus-2s bridge cutoff. This
        # child reserves another 2s inside that cutoff for exact-child cleanup.
        self.api, self.end, self.frequency = api, request["deadlineTicks"], request["frequency"]
        if api.frequency() != self.frequency or not 0 < self.remaining() <= 30:
            raise ValueError("invalid deadline")

    def remaining(self):
        return max(0.0, (self.end - self.api.ticks()) / self.frequency)


def diagnostic_runtime_request(rows):
    """Optional internal observations only; paths never become receipt fields."""
    if type(rows) is not list or len(rows) != 14:
        raise ValueError("runtime unavailable")
    parents, names, total = set(), set(), 0
    for row in rows:
        if type(row) is not dict or set(row) != {"name", "path", "bytes", "sha256"}:
            raise ValueError("runtime unavailable")
        name, location = row["name"], row["path"]
        if type(name) is not str or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*\.dll", name) or \
                name.casefold() in names or type(location) is not str or len(location) > 4096 or \
                not re.match(r"^[A-Za-z]:\\", location) or ntpath.normpath(location) != location or \
                ntpath.basename(location) != name or any(ord(c) < 32 for c in location) or \
                any(c in location for c in '\";') or ":" in location[2:] or \
                type(row["bytes"]) is not int or not 0 < row["bytes"] <= 64 << 20 or \
                type(row["sha256"]) is not str or not re.fullmatch(r"[0-9a-f]{64}", row["sha256"]):
            raise ValueError("runtime unavailable")
        names.add(name.casefold()); parents.add(ntpath.dirname(location).casefold()); total += row["bytes"]
    if len(parents) != 1 or total > 64 << 20:
        raise ValueError("runtime unavailable")
    return rows


def diagnostic_runtime_layout():
    """Use the canonical ARM installer pin, lock and runtime-name policy."""
    version, pin, _ = windows_targets.swift_runtime_installer("arm64")
    lock = json.loads((HERE / windows_targets.target("arm64")["swiftRuntimeLock"]).read_text(encoding="utf-8"))
    installer = lock.get("installer") or {}
    if lock.get("architecture") != "arm64" or lock.get("swiftVersion") != version or \
            any(installer.get(key) != pin[key] for key in ("name", "url", "sha256")) or \
            not windows_targets.installer_size_matches(pin, installer.get("bytes")):
        raise ValueError("runtime unavailable")
    policy = json.loads((HERE / "runtime-policy.json").read_text(encoding="utf-8"))["swiftRuntimeModules"]
    layout = {row["path"]: row for row in lock["files"]}
    if len(layout) != len(lock["files"]) or len(set(policy)) != len(policy):
        raise ValueError("runtime unavailable")
    return version, {name: layout[name] for name in policy}


def diagnostic_runtime_stamp(path, directory=False):
    for component in (path, *path.parents):
        info = component.lstat()
        if getattr(info, "st_file_attributes", 0) & 0x400 or stat.S_ISLNK(info.st_mode):
            raise ValueError("runtime unavailable")
    info = path.lstat()
    if not (stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode)):
        raise ValueError("runtime unavailable")
    return info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns


def diagnostic_runtime_bytes(path, row, budget):
    before = diagnostic_runtime_stamp(path)
    if before[2] != row["bytes"]:
        raise ValueError("runtime unavailable")
    stamp = lambda info: (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns)
    with path.open("rb") as stream:
        if stamp(os.fstat(stream.fileno())) != before:
            raise ValueError("runtime unavailable")
        data = bytearray()
        while len(data) < row["bytes"]:
            if budget.remaining() <= 2:
                raise TimeoutError()
            chunk = stream.read(min(1 << 20, row["bytes"] - len(data)))
            if not chunk:
                raise ValueError("runtime unavailable")
            data.extend(chunk)
        if stamp(os.fstat(stream.fileno())) != before:
            raise ValueError("runtime unavailable")
    if diagnostic_runtime_stamp(path) != before or hashlib.sha256(data).hexdigest() != row["sha256"]:
        raise ValueError("runtime unavailable")
    image = windows_pe.PEImage(data, "owned-diagnostic-runtime")
    if image.architecture != "arm64" or not image.is_dll:
        raise ValueError("runtime unavailable")
    return data, before


def prepare_diagnostic_runtime(rows, directory, budget):
    """Copy only pinned snapshots; never admit a user-writable source to PATH."""
    diagnostic_runtime_request(rows)
    version, layout = diagnostic_runtime_layout()
    parent = ntpath.dirname(rows[0]["path"])
    prefix = r'^[A-Za-z]:\\Users\\[^\\/:;"<>|?*\x00-\x1f]{1,128}\\AppData\\Local\\Programs\\Swift\\Runtimes\\'
    if not re.fullmatch(prefix + re.escape(version) + r'\\usr\\bin', parent, re.IGNORECASE):
        raise ValueError("runtime unavailable")
    source_parent = pathlib.Path(parent)
    parent_stamp = diagnostic_runtime_stamp(source_parent, directory=True)
    private = pathlib.Path(directory) / "runtime"
    private.mkdir(mode=0o700)
    sources, copies = [], []
    for row in rows:
        pinned = layout.get(row["name"])
        if pinned is None or row["bytes"] != pinned["bytes"] or row["sha256"] != pinned["sha256"]:
            raise ValueError("runtime unavailable")
        path = pathlib.Path(row["path"])
        data, source_stamp = diagnostic_runtime_bytes(path, row, budget)
        destination = private / row["name"]
        with destination.open("xb") as stream:
            for offset in range(0, len(data), 1 << 20):
                if budget.remaining() <= 2:
                    raise TimeoutError()
                stream.write(memoryview(data)[offset:offset + (1 << 20)])
        sources.append((path, source_stamp))
        copies.append((destination, row, diagnostic_runtime_stamp(destination)))
    if diagnostic_runtime_stamp(source_parent, directory=True) != parent_stamp or \
            any(diagnostic_runtime_stamp(path) != stamp for path, stamp in sources):
        raise ValueError("runtime unavailable")
    for path, row, stamp in copies:
        _, current = diagnostic_runtime_bytes(path, row, budget)
        if current != stamp:
            raise ValueError("runtime unavailable")
    # Enumerate only our newly created private directory, at most15 entries;
    # source/toolchain siblings are never scanned or admitted.
    copied_names = set()
    with os.scandir(private) as entries:
        for entry in entries:
            if len(copied_names) >= 14 or not entry.is_file(follow_symlinks=False):
                raise ValueError("runtime unavailable")
            copied_names.add(entry.name)
    if copied_names != {row["name"] for row in rows}:
        raise ValueError("runtime unavailable")
    if budget.remaining() <= 2:
        raise TimeoutError()
    return str(private)


def diagnostic_identity(location, digest, maximum, budget, version=None):
    """Fresh regular non-reparse image snapshot; no image is loaded/executed."""
    path = pathlib.Path(location)
    for component in (path, *path.parents):
        info = component.lstat()
        if getattr(info, "st_file_attributes", 0) & 0x400 or stat.S_ISLNK(info.st_mode):
            raise ValueError("alias refused")
    before = path.lstat()
    if not stat.S_ISREG(before.st_mode) or not 0 < before.st_size <= maximum:
        raise ValueError("image refused")
    stamp = lambda info: (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns)
    with path.open("rb") as stream:
        if stamp(os.fstat(stream.fileno())) != stamp(before):
            raise ValueError("image changed")
        data = bytearray()
        while len(data) < before.st_size:
            if budget.remaining() <= 2:
                raise TimeoutError()
            chunk = stream.read(min(1 << 20, before.st_size - len(data)))
            if not chunk:
                raise ValueError("short image")
            data.extend(chunk)
        after = os.fstat(stream.fileno())
    if stamp(after) != stamp(before) or stamp(path.lstat()) != stamp(before) or \
            hashlib.sha256(data).hexdigest() != digest:
        raise ValueError("image changed")
    image = windows_pe.PEImage(data, "owned-diagnostic-image")
    if image.is_dll or (ntpath.basename(location).casefold() in ("speakwindows.exe", "cdb.exe") and
                        image.architecture != "arm64") or (version is not None and numeric_file_version(path) != version):
        raise ValueError("image refused")
    if stamp(path.lstat()) != stamp(before):
        raise ValueError("image changed")
    return stamp(before)


class DiagnosticPipeReader:
    """Peek first: no blocking read-to-EOF and no reader threads/daemon lifetime."""
    def __init__(self):
        if os.name != "nt":
            raise OSError("unsupported")
        import ctypes
        import msvcrt
        self.ctypes, self.handle = ctypes, msvcrt.get_osfhandle
        api = ctypes.WinDLL("kernel32", use_last_error=True, winmode=0x800)
        self.peek = api.PeekNamedPipe
        self.peek.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_uint32,
                              ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint32), ctypes.c_void_p]
        self.peek.restype = ctypes.c_int32

    def read(self, stream, maximum=4096):
        available = self.ctypes.c_uint32()
        if not self.peek(self.handle(stream.fileno()), None, 0, None, self.ctypes.byref(available), None):
            if self.ctypes.get_last_error() in (109, 232):  # Broken pipe / no-data pipe closing.
                return b"", True
            raise OSError("pipe unavailable")
        if not available.value:
            return b"", False
        if maximum <= 0:
            raise OverflowError()  # Peek proves extra output; consume nothing beyond the combined cap.
        return os.read(stream.fileno(), min(available.value, 4096, maximum)), False


def bounded_diagnostic_process(argv, environment, directory, budget, seconds, line_limit=2048,
                               launch=subprocess.Popen, pipe_factory=DiagnosticPipeReader,
                               clock=time.monotonic, sleep=time.sleep):
    """Only local CreateProcess descendants; bounded memory, no raw persistence.

    Parent job is the ultimate tree owner. Exact child wait is not represented
    as a verified tree reap; the PS owner independently terminates/accounts it.
    """
    if min(seconds, budget.remaining() - 2) <= 0:
        return {"status": "deadline", "cleanup": "not-started", "output": b"", "exitCode": None}
    end = clock() + min(seconds, budget.remaining() - 2)
    process, output, total, lines = None, [bytearray(), bytearray()], 0, [0, 0]
    status, cleanup = "unavailable", "not-started"
    try:
        pipes = pipe_factory()
        process = launch(argv, executable=argv[0], cwd=directory, env=environment, stdin=subprocess.DEVNULL,
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0, close_fds=True,
                         creationflags=0)  # No shell, alternate parent or BREAKAWAY.
        cleanup, closed = "clean", set()
        while True:
            if clock() >= end or budget.remaining() <= 2:
                status = "deadline"
                break
            progress = False
            for index, stream in enumerate((process.stdout, process.stderr)):
                if index in closed:
                    continue
                maximum = min(4096, 65536 - total)
                chunk, eof = pipes.read(stream, maximum)
                if not isinstance(chunk, bytes) or len(chunk) > maximum or type(eof) is not bool:
                    raise ValueError("invalid pipe projection")
                if eof:
                    closed.add(index)
                if not chunk:
                    continue
                progress, total = True, total + len(chunk)
                for byte in chunk:
                    lines[index] = 0 if byte in (10, 13) else lines[index] + 1
                    if lines[index] > line_limit:
                        status = "truncated"
                        break
                if total > 65536 or status == "truncated":
                    status = "truncated"
                    break
                output[index].extend(chunk)
            if status == "truncated":
                break
            if len(closed) == 2 and process.poll() is not None:
                status = "complete"
                break
            if not progress:
                wait = max(0.0, min(0.005, budget.remaining() - 2, end - clock()))
                if wait:
                    if process.poll() is None:
                        try:
                            process.wait(timeout=wait)
                        except subprocess.TimeoutExpired:
                            pass
                    else:
                        sleep(wait)  # Held descendant pipe: keep checking cap/deadline, never EOF-read.
    except OverflowError:
        status = "truncated"
    except Exception:
        status = "unavailable"
    finally:
        if process is not None:
            try:
                if process.poll() is None:
                    process.kill()  # Exact returned child; PS separately terminates the whole private job.
                process.wait(timeout=max(0.001, min(1.0, budget.remaining())))
            except Exception:
                cleanup = "failed"
            for stream in (process.stdout, process.stderr):
                if stream:
                    try:
                        stream.close()  # Raw FileIO only; there is no concurrent reader/BufferedReader lock.
                    except Exception:
                        cleanup = "failed"
    return {"status": status, "cleanup": cleanup,
            "output": bytes(output[0]) + bytes(output[1]),
            "exitCode": process.returncode if process else None}


def project_debugger(data, completed=True, *, completion_class="unknown"):
    """Only addresses within one unambiguous module range become closed RVAs."""
    if type(completion_class) is not str or completion_class not in ("zero", "nonzero", "unknown"):
        raise ValueError("invalid completion class")
    unknown = {"status": "invalid", "exceptionCode": None, "frames": []}
    if not isinstance(data, bytes) or len(data) > 65536 or any(len(line) > 2048 for line in data.splitlines()):
        return {**unknown, "status": "truncated"}
    # Paths/function text may use the local console encoding. They are never
    # exported; only the strict ASCII grammar below contributes any output.
    text = data.decode("ascii", errors="replace")
    lines = text.splitlines()
    # Counts describe bounded input markers and parsed-prefix row matches, not
    # raw text. Seventeen is a saturation value meaning seventeen or more.
    counts = {"ready": min(17, lines.count("JSTI_DIAG_READY")),
              "fault": min(17, sum(line.startswith("JSTI_DIAG_FAULT ") for line in lines)),
              "end": min(17, lines.count("JSTI_DIAG_END")),
              "modules": min(17, lines.count("JSTI_DIAG_MODULES")),
              "stack": min(17, lines.count("JSTI_DIAG_STACK")),
              "ip": 0, "moduleRanges": 0, "stackRows": 0}

    def refuse(reason):
        return {**unknown, "refusalFacts": {"reason": reason, "completionClass": completion_class,
                                           "counts": dict(counts)}}
    if lines.count("JSTI_DIAG_READY") != 1:
        return refuse("ready-marker-count")
    begins = [index for index, line in enumerate(lines) if line.startswith("JSTI_DIAG_FAULT ")]
    if not begins:
        return {**unknown, "status": "no-reproduction" if completed else "unavailable"}
    if len(begins) != 1 or lines.count("JSTI_DIAG_END") != 1:
        return refuse("fault-boundary")
    first, last = begins[0], lines.index("JSTI_DIAG_END")
    if first >= last or not re.fullmatch(r"JSTI_DIAG_FAULT 0x(?:c0000005|c0000374|c0000409)", lines[first]):
        return refuse("fault-code-order")
    body, ranges, addresses = lines[first + 1:last], [], []
    if body.count("JSTI_DIAG_MODULES") != 1 or body.count("JSTI_DIAG_STACK") != 1:
        return refuse("section-boundary")
    modules_at, stack_at = body.index("JSTI_DIAG_MODULES"), body.index("JSTI_DIAG_STACK")
    if modules_at >= stack_at:
        return refuse("section-boundary")
    for line in body[:modules_at]:
        match = re.fullmatch(r"JSTI_DIAG_IP ([0-9a-fA-F`]{1,17})", line)
        if match:
            counts["ip"] = min(17, counts["ip"] + 1)
            addresses.append(int(match[1].replace("`", ""), 16))
    if len(addresses) != 1:
        return refuse("ip-count")
    for line in body[modules_at + 1:stack_at]:
        match = re.match(r"^([0-9a-fA-F`]{1,17})\s+([0-9a-fA-F`]{1,17})\s+([A-Za-z0-9_.-]{1,128})(?:\s|$)", line)
        if match:
            counts["moduleRanges"] = min(17, counts["moduleRanges"] + 1)
            low, high = (int(match[n].replace("`", ""), 16) for n in (1, 2))
            if not 0 <= low < high < (1 << 64):
                return refuse("module-range")
            ranges.append((low, high, closed_module(match[3])))
    stack_count = 0
    for line in body[stack_at + 1:]:
        match = re.match(r"^\s*([0-9a-fA-F]{2})\s+([0-9a-fA-F`]{1,17})\s+([0-9a-fA-F`]{1,17})(?:\s|$)", line)
        if match:
            counts["stackRows"] = min(17, counts["stackRows"] + 1)
            if int(match[1], 16) != stack_count or stack_count >= 16:
                return refuse("stack-row-order")
            stack_count += 1
            returned = int(match[3].replace("`", ""), 16)
            if returned:
                addresses.append(returned)  # Return PC, never a function displacement.
    if not stack_count:
        return refuse("stack-row-count")
    frames = []
    for address in addresses[:16]:
        owned = [(low, high, name) for low, high, name in ranges if low <= address < high]
        if len(owned) != 1:
            return refuse("frame-range")
        low, _, name = owned[0]
        frames.append({"index": len(frames), "module": name, "rva": "0x%x" % (address - low)})
    if not frames:
        return refuse("frame-count")
    return {"status": "observed", "exceptionCode": lines[first].split()[1], "frames": frames}


def pre_ready_process_facts(code, data):
    """Closed exit-value facts, never a claim about why the debugger exited."""
    if type(code) is not int or not -(1 << 31) <= code <= (1 << 32) - 1 or not isinstance(data, bytes) or len(data) > 65536:
        return None
    # Microsoft MS-ERREF defines these exact NTSTATUS values. ExitProcess/main
    # can also return them, so their names classify the value, not its cause:
    # https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-erref/596a1078-e883-4972-9bbc-49e60bebca55
    known = {0: "zero", 0xC0000135: "dllNotFoundStatus", 0xC000007B: "invalidImageFormatStatus",
             0xC0000139: "entryPointNotFoundStatus"}
    return {"exitStatusClass": known.get(code & 0xFFFFFFFF, "otherNonzero"),
            "outputClass": "nonempty" if data else "empty"}


def cdb_commands():
    lines = []
    for code in CRASH_CODES.values():
        command = ('.printf \\"JSTI_DIAG_FAULT %s\\n\\"; .printf \\"JSTI_DIAG_IP %%p\\n\\", @$ip; '
                   '.printf \\"JSTI_DIAG_MODULES\\n\\"; lmon; .printf \\"JSTI_DIAG_STACK\\n\\"; '
                   'kL 0n16; .printf \\"JSTI_DIAG_END\\n\\"; q') % code
        lines.append('sxd -c2 "%s" %s' % (command, code))
    return "\n".join(lines) + '\n.printf "JSTI_DIAG_READY\\n"\ng\n'


def standalone_diagnostic(encoded, api_factory=StandaloneWindows, identity=diagnostic_identity,
                          runner=bounded_diagnostic_process):
    result = diagnostic_result("invalid")
    scratch = None
    try:
        request = diagnostic_request(encoded)
        api = api_factory()
        budget = DiagnosticBudget(request, api)
        if not api.admitted(request):
            return result
        result = diagnostic_result()
        app = identity(request["executable"], request["expectedSHA256"], 128 << 20, budget)
        host = identity(request["powershell"], request["powershellSHA256"], 32 << 20, budget)
        # Only fixed system/temp variables; no inherited OP/API/symbol/debugger configuration.
        scratch = tempfile.TemporaryDirectory(prefix="jsti-owned-diagnostic-")
        with scratch as directory:
            environment = {key: os.environ[key] for key in ("SystemRoot", "WINDIR") if key in os.environ}
            environment.update(PATH=ntpath.join(environment.get("SystemRoot", r"C:\Windows"), "System32"),
                               TEMP=directory, TMP=directory, USERPROFILE=directory, HOME=directory,
                               APPDATA=directory, LOCALAPPDATA=directory)
            if budget.remaining() >= 7:
                env = dict(environment, JSTI_EVENT_START=request["startedUTC"], JSTI_EVENT_END=request["endedUTC"])
                event = runner([request["powershell"], "-NoLogo", "-NoProfile", "-NonInteractive", "-Command",
                                APPLICATION_ERROR_QUERY], env, directory, budget, 5, line_limit=65536)
                result["cleanup"] = event["cleanup"]
                if event["cleanup"] == "failed":
                    return result
                projection = {"status": "unavailable"}
                if event["status"] == "complete" and event["exitCode"] == 0:
                    try:
                        payload = json.loads(event["output"].decode("utf-8-sig"), object_pairs_hook=unique_json)
                        if isinstance(payload, dict) and set(payload) == {"status", "events"} and payload["status"] == "ok":
                            start = datetime.datetime.fromisoformat(request["startedUTC"].replace("Z", "+00:00"))
                            end = datetime.datetime.fromisoformat(request["endedUTC"].replace("Z", "+00:00"))
                            projection = project_application_error(payload["events"], request["originalPid"],
                                                                   request["executable"], start, end)
                    except Exception:
                        projection = {"status": "invalid"}
                elif event["status"] in ("deadline", "truncated"):
                    projection = {"status": "timeout" if event["status"] == "deadline" else "invalid"}
                if projection["status"] == "observed":
                    module = closed_module(projection["module"])
                    projection = {key: projection[key] for key in ("status", "version", "exceptionCode", "faultOffset")}
                    projection["module"] = module
                result["applicationError"] = projection
            if budget.remaining() - 2 < 5:
                result["status"] = result["debugger"]["status"] = "deadline"
                return result
            identity(CDB_LOCATION, CDB_SHA256, 32 << 20, budget, version=CDB_VERSION)
            # Recheck the caller-admitted images after optional Event1000 work.
            if identity(request["executable"], request["expectedSHA256"], 128 << 20, budget) != app or \
                    identity(request["powershell"], request["powershellSHA256"], 32 << 20, budget) != host:
                return result
            if budget.remaining() - 2 < 5:
                result["status"] = result["debugger"]["status"] = "deadline"
                return result
            symbols = pathlib.Path(directory) / "symbols"
            symbols.mkdir()
            command = pathlib.Path(directory) / "fixed-cdb.txt"
            command.write_text(cdb_commands(), encoding="ascii")
            argv = [CDB_LOCATION, "-hd", "-G", "-sins", "-noshell", "-nosqm", "-netsyms:no", "-cf", str(command),
                    "-y", str(symbols), request["executable"], "--ui-smoke-test"]
            debugger_environment = environment
            if "runtimeModules" in request:
                runtime = prepare_diagnostic_runtime(request["runtimeModules"], directory, budget)
                if budget.remaining() - 2 < 5:
                    result["status"] = result["debugger"]["status"] = "deadline"
                    return result
                debugger_environment = dict(environment, PATH=environment["PATH"] + ";" + runtime)
            observed = runner(argv, debugger_environment, directory, budget, min(20, budget.remaining() - 2))
            result["cleanup"] = observed["cleanup"]
            if observed["cleanup"] == "failed":
                return result
            if observed["status"] != "complete":
                status = observed["status"] if observed["status"] in STANDALONE_STATUSES else "unavailable"
                result["status"] = result["debugger"]["status"] = status
                return result
            code = observed["exitCode"]
            completion = "zero" if type(code) is int and code == 0 else "nonzero" if type(code) is int else "unknown"
            result["debugger"] = project_debugger(observed["output"], observed["exitCode"] == 0,
                                                  completion_class=completion)
            refusal = result["debugger"].get("refusalFacts")
            if refusal is not None and refusal["reason"] == "ready-marker-count" and refusal["counts"]["ready"] == 0:
                process_facts = pre_ready_process_facts(code, observed["output"])
                if process_facts is not None:
                    refusal["processFacts"] = process_facts
            result["status"] = result["debugger"]["status"]
            if result["applicationError"]["status"] == "observed" and result["status"] == "no-reproduction":
                result["status"] = "observed"
    except TimeoutError:
        result["status"] = result["debugger"]["status"] = "deadline"
    except Exception:
        # Neither an unexpected optional collector error nor temporary cleanup
        # failure may leave a previously observed result looking completed.
        if scratch is not None:
            try:
                if pathlib.Path(scratch.name).exists():
                    result["cleanup"] = "failed"
            except Exception:
                result["cleanup"] = "failed"
        result["status"] = result["debugger"]["status"] = "unavailable"
        result["debugger"]["exceptionCode"], result["debugger"]["frames"] = None, []
    # Late cleanup/cutoff cannot leave parser facts looking current. This adds
    # no status, retry, budget or acceptance change to the original operation.
    if "refusalFacts" in result["debugger"]:
        try:
            if result["cleanup"] != "clean" or result["status"] != "invalid" or budget.remaining() <= 2:
                result["debugger"].pop("refusalFacts", None)
        except Exception:
            result["debugger"].pop("refusalFacts", None)
    return result


PACKAGED_EVENT_KEYS = {"schema", "architecture", "label", "exitCode", "originalPid", "startedUTC", "endedUTC",
                       "executable", "expectedSHA256", "powershell", "powershellSHA256", "parentPid",
                       "startedTicks", "endedTicks", "originalDeadlineTicks", "deadlineTicks", "frequency"}


def packaged_event_request(encoded):
    """Separate event-only contract; never widens the existing standalone request."""
    if not isinstance(encoded, str) or not 0 < len(encoded) <= 10924 or not re.fullmatch(r"[A-Za-z0-9_-]+", encoded):
        raise ValueError("invalid request")
    raw = base64.b64decode(encoded + "=" * (-len(encoded) % 4), altchars=b"-_", validate=True)
    if len(raw) > 8192:
        raise ValueError("invalid request")
    value = json.loads(raw.decode("utf-8"), object_pairs_hook=unique_json)
    if not isinstance(value, dict) or set(value) != PACKAGED_EVENT_KEYS or type(value["schema"]) is not int or \
            value["schema"] != 1 or value["architecture"] != "arm64" or value["label"] != "base-ui-smoke-test" or \
            type(value["exitCode"]) is not int or value["exitCode"] not in CRASH_CODES:
        raise ValueError("invalid request")
    for key in ("originalPid", "parentPid", "startedTicks", "endedTicks", "originalDeadlineTicks", "deadlineTicks", "frequency"):
        if type(value[key]) is not int or not 0 < value[key] < (1 << (32 if key.endswith("Pid") else 63)):
            raise ValueError("invalid request")
    frequency = value["frequency"]
    if frequency > 1000000000 or value["originalDeadlineTicks"] - value["startedTicks"] != 60 * frequency or not \
            value["startedTicks"] <= value["endedTicks"] < value["deadlineTicks"] <= value["originalDeadlineTicks"]:
        raise ValueError("invalid request")
    for key in ("expectedSHA256", "powershellSHA256"):
        if not isinstance(value[key], str) or not re.fullmatch(r"[0-9a-f]{64}", value[key]):
            raise ValueError("invalid request")
    for key, name in (("executable", "speakwindows.exe"), ("powershell", "powershell.exe")):
        text = value[key]
        if not isinstance(text, str) or len(text) > 4096 or not re.match(r"^[A-Za-z]:\\", text) or \
                any(ord(c) < 32 for c in text) or '"' in text or ":" in text[2:] or \
                ntpath.basename(text).casefold() != name or ntpath.normpath(text) != text:
            raise ValueError("invalid request")
    system = os.environ.get("SystemRoot", r"C:\Windows")
    fixed_host = ntpath.join(system, r"System32\WindowsPowerShell\v1.0\powershell.exe")
    if ntpath.normcase(value["powershell"]) != ntpath.normcase(fixed_host):
        raise ValueError("invalid request")
    moments = []
    for key in ("startedUTC", "endedUTC"):
        text = value[key]
        if not isinstance(text, str) or len(text) > 40:
            raise ValueError("invalid request")
        moment = datetime.datetime.fromisoformat(text.replace("Z", "+00:00"))
        if moment.tzinfo is None or moment.utcoffset() != datetime.timedelta(0):
            raise ValueError("invalid request")
        moments.append(moment)
    if not 0 <= (moments[1] - moments[0]).total_seconds() <= 60:
        raise ValueError("invalid request")
    return value


def packaged_event_result(status="unavailable", cleanup="not-started"):
    return {"schema": 1, "status": status, "cleanup": cleanup, "applicationError": {"status": "unavailable"}}


def packaged_application_error(encoded, api_factory=StandaloneWindows, runner=bounded_diagnostic_process,
                               identity=diagnostic_identity):
    """One original Event1000 query only. No target, debugger, retry or raw persistence."""
    result = packaged_event_result()
    scratch = None
    try:
        request = packaged_event_request(encoded)
        api = api_factory()
        budget = DiagnosticBudget(request, api)
        if not api.admitted(request) or api.ticks() < request["endedTicks"] or budget.remaining() > 10:
            return result
        app = identity(request["executable"], request["expectedSHA256"], 128 << 20, budget)
        host = identity(request["powershell"], request["powershellSHA256"], 32 << 20, budget)
        if budget.remaining() < 7:
            return packaged_event_result("deadline")
        scratch = tempfile.TemporaryDirectory(prefix="jsti-packaged-event-")
        environment = {key: os.environ[key] for key in ("SystemRoot", "WINDIR") if key in os.environ}
        environment.update(PATH=ntpath.join(environment.get("SystemRoot", r"C:\Windows"), "System32"),
                           TEMP=scratch.name, TMP=scratch.name, USERPROFILE=scratch.name, HOME=scratch.name,
                           APPDATA=scratch.name, LOCALAPPDATA=scratch.name,
                           JSTI_EVENT_START=request["startedUTC"], JSTI_EVENT_END=request["endedUTC"])
        event = runner([request["powershell"], "-NoLogo", "-NoProfile", "-NonInteractive", "-Command",
                        APPLICATION_ERROR_QUERY], environment, scratch.name, budget, 5, line_limit=65536)
        result["cleanup"] = event["cleanup"]
        if event["cleanup"] != "clean":
            return result
        if event["status"] != "complete" or event["exitCode"] != 0:
            if event["status"] == "deadline":
                result["status"], result["applicationError"] = "deadline", {"status": "timeout"}
            elif event["status"] == "truncated":
                result["status"], result["applicationError"] = "truncated", {"status": "invalid"}
            return result
        if not isinstance(event["output"], bytes) or len(event["output"]) > 65536:
            result = packaged_event_result("invalid", "clean")
            return result
        payload = json.loads(event["output"].decode("utf-8-sig"), object_pairs_hook=unique_json)
        if payload == {"status": "unavailable"}:
            return result
        if not isinstance(payload, dict) or set(payload) != {"status", "events"} or payload["status"] != "ok":
            result = packaged_event_result("invalid", "clean")
            return result
        start = datetime.datetime.fromisoformat(request["startedUTC"].replace("Z", "+00:00"))
        end = datetime.datetime.fromisoformat(request["endedUTC"].replace("Z", "+00:00"))
        projection = project_application_error(payload["events"], request["originalPid"], request["executable"], start, end)
        if projection["status"] == "observed" and projection["exceptionCode"] != CRASH_CODES[request["exitCode"]]:
            projection = {"status": "invalid"}
        if projection["status"] == "observed":
            projection = {"status": "observed", "module": closed_module(projection["module"]),
                          **{key: projection[key] for key in ("version", "exceptionCode", "faultOffset")}}
        if identity(request["executable"], request["expectedSHA256"], 128 << 20, budget) != app or \
                identity(request["powershell"], request["powershellSHA256"], 32 << 20, budget) != host:
            return result
        if budget.remaining() <= 2:
            result = packaged_event_result("deadline", "clean")
            return result
        result["applicationError"] = projection
        result["status"] = "observed" if projection["status"] == "observed" else "unavailable"
    except (ValueError, TypeError, KeyError, UnicodeError, OSError):
        result["status"] = "invalid"
    except Exception:
        result["status"] = "unavailable"
    finally:
        if scratch is not None:
            try:
                scratch.cleanup()
            except Exception:
                result.clear()
                result.update(packaged_event_result("unavailable", "failed"))
    return result


def packaged_event_main(argv):
    result = packaged_event_result("invalid")
    if len(argv) == 3 and argv[1] == "--request":
        result = packaged_application_error(argv[2])
    serialized = json.dumps(result, separators=(",", ":"), ensure_ascii=True)
    if len(serialized.encode("ascii")) > 8192:
        serialized = json.dumps(packaged_event_result("invalid"), separators=(",", ":"))
    print(serialized)


def standalone_main(argv):
    result = diagnostic_result("invalid")
    if len(argv) == 3 and argv[1] == "--request":
        result = standalone_diagnostic(argv[2])
    serialized = json.dumps(result, separators=(",", ":"), ensure_ascii=True)
    if len(serialized.encode("ascii")) > 8192:
        serialized = json.dumps(diagnostic_result("invalid"), separators=(",", ":"))
    print(serialized)


def parse_arguments(argv=None):
    # No abbreviations: the program's own options (for example --expect) follow
    # "--" and must reach it unchanged.
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter,
                                     allow_abbrev=False)
    parser.add_argument("--architecture", required=True, choices=sorted(windows_targets.TARGETS))
    parser.add_argument("--evidence", required=True, type=pathlib.Path, help="JSON evidence file to create or extend")
    commands = parser.add_subparsers(dest="command", required=True)
    host = commands.add_parser("host", help="require a native host and record the toolchain images", allow_abbrev=False)
    host.add_argument("--toolchain", action="append", default=[], help="toolchain executable to record")
    images = commands.add_parser("images", help="require native PE images", allow_abbrev=False)
    images.add_argument("paths", nargs="+")
    execute = commands.add_parser("run", help="run a program and require native, successful execution",
                                  allow_abbrev=False)
    execute.add_argument("--label", required=True)
    execute.add_argument("--timeout", type=float, required=True, help="seconds before the process is killed")
    execute.add_argument("--stdout", required=True, type=pathlib.Path)
    execute.add_argument("--stderr", required=True, type=pathlib.Path)
    execute.add_argument("--expect-output", action="append", default=[], help="text stdout or stderr must contain")
    execute.add_argument("--diagnostic-owner-context", action="store_true",
                         help="trusted ARM64 UI caller owns optional diagnostics within the same QPC deadline")
    execute.add_argument("--deadline-ticks", type=int)
    execute.add_argument("--deadline-frequency", type=int)
    execute.add_argument("arguments", nargs=argparse.REMAINDER, help="-- program [arguments]")
    args = parser.parse_args(argv)
    if args.command == "run":
        args.arguments = args.arguments[1:] if args.arguments[:1] == ["--"] else args.arguments
        if not args.arguments:
            parser.error("run needs a program after --")
    return args


def main(argv=None):
    args = parse_arguments(argv)
    evidence = load_evidence(args.evidence, args.architecture)
    try:
        if args.command == "images":
            evidence["images"].extend(check_images(args.paths, args.architecture))
            print("%d native %s images" % (len(args.paths), args.architecture))
            return
        if os.name != "nt":
            raise ExecutionError("the %s check inspects Windows processes and runs on Windows only" % args.command)
        api = WindowsAPI()
        if args.command == "host":
            evidence["host"] = check_host(api, args.architecture, args.toolchain)
            print(json.dumps(evidence["host"], indent=2, sort_keys=True))
            return
        record = run(args.arguments, api, args.architecture, args.label, args.timeout, args.stdout, args.stderr,
                     args.expect_output, diagnostic_owner_context=args.diagnostic_owner_context,
                     deadline_ticks=args.deadline_ticks, deadline_frequency=args.deadline_frequency)
        evidence["runs"].append(record)
        for path in (args.stdout, args.stderr):
            sys.stdout.write(pathlib.Path(path).read_text(encoding="utf-8", errors="replace"))
        print("%s: %s process, exit %s, %d modules, %.1f s" % (
            args.label, record["processMachine"], record["exitCode"], record["modulesObserved"], record["seconds"]))
        if record["failures"]:
            raise ExecutionError("%s: %s" % (args.label, "; ".join(record["failures"])))
    finally:
        save_evidence(args.evidence, evidence)


def dispatch_main(argv=None):
    arguments = sys.argv[1:] if argv is None else argv
    if arguments[:1] == ["packaged-application-error"]:
        return packaged_event_main(arguments)
    if arguments[:1] == ["standalone-diagnostic"]:
        return standalone_main(arguments)
    return main(arguments)


if __name__ == "__main__":
    try:
        dispatch_main()
    except (ExecutionError, windows_pe.PEFormatError, OSError, ValueError) as error:
        raise SystemExit("native execution: " + str(error))
