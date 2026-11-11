"""Bounded diagnostic children: the job/QPC clock, the deadline budget, image identity snapshots and the bounded process runner.

Part of verify-native-execution.py, which owns the command line.
"""
import hashlib
import ntpath
import os
import pathlib
import stat
import subprocess
import time

import windows_pe
from native_execution_host import numeric_file_version


def diagnostic_preparation_phase(budget, phase):
    # Only an admitted operation owns this private tracker; old direct callers do not.
    tracker = getattr(budget, "_diagnostic_preparation", None)
    if type(tracker) is dict:
        tracker["lastPhase"] = phase


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
