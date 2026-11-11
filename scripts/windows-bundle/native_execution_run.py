"""The run phase: launch a program, observe its process machine and modules, assess native execution and read its Application Error event.

Part of verify-native-execution.py, which owns the command line.
"""
import datetime
import json
import ntpath
import os
import pathlib
import re
import shutil
import subprocess
import time

import windows_pe
import windows_targets
from native_execution_host import (
    EMULATION_MODULES, ExecutionError, check_images, describe_image, machine_name, query_machine
)
from native_execution_process import StandaloneWindows


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
CRASH_CODES = {-1073741819: "0xc0000005", -1073740940: "0xc0000374", -1073740791: "0xc0000409"}
