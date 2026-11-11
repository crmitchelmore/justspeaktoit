"""Host and image evidence: PE image facts, the host machine, diagnostic tool inventory and the evidence file.

Part of verify-native-execution.py, which owns the command line.
"""
import hashlib
import json
import os
import pathlib
import platform
import stat
import time

import windows_pe
import windows_targets


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
