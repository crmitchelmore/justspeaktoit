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
import hashlib
import json
import os
import pathlib
import platform
import shutil
import subprocess
import sys
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
            "architecture": image.architecture, "dll": image.is_dll, "native": image.runs_natively_on(architecture)}


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


def run(arguments, api, architecture, label, timeout, stdout_path, stderr_path, expected_output=(),
        system_root=None, launch=subprocess.Popen, read_image=describe_image):
    """Run ``arguments`` and return its evidence record; ``failures`` lists what was not native or successful.

    A program that is not a native image is refused before it starts.
    """
    executable = shutil.which(arguments[0]) or arguments[0]
    main_image = check_images([executable], architecture)[0]
    with open(stdout_path, "wb") as stdout, open(stderr_path, "wb") as stderr:
        process = launch([executable] + list(arguments[1:]), stdout=stdout, stderr=stderr)
        observation = observe(process, api, timeout=timeout)
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
    return record


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
                     args.expect_output)
        evidence["runs"].append(record)
        for path in (args.stdout, args.stderr):
            sys.stdout.write(pathlib.Path(path).read_text(encoding="utf-8", errors="replace"))
        print("%s: %s process, exit %s, %d modules, %.1f s" % (
            args.label, record["processMachine"], record["exitCode"], record["modulesObserved"], record["seconds"]))
        if record["failures"]:
            raise ExecutionError("%s: %s" % (args.label, "; ".join(record["failures"])))
    finally:
        save_evidence(args.evidence, evidence)


if __name__ == "__main__":
    try:
        main()
    except (ExecutionError, windows_pe.PEFormatError, OSError, ValueError) as error:
        raise SystemExit("native execution: " + str(error))
