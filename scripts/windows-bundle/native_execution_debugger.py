"""The private failure-only standalone diagnostic: request, CDB run and the closed projection of what it observed.

Part of verify-native-execution.py, which owns the command line.
"""
import base64
import datetime
import json
import ntpath
import os
import pathlib
import re
import tempfile

from native_execution_process import (
    DiagnosticBudget,
    StandaloneWindows,
    bounded_diagnostic_process,
    diagnostic_identity,
    diagnostic_preparation_phase,
)
from native_execution_run import APPLICATION_ERROR_QUERY, CRASH_CODES, project_application_error
from native_execution_runtime import diagnostic_runtime_request, prepare_diagnostic_runtime

# --- Private failure-only standalone diagnostic -------------------------------------
# This is not an authenticated service or a qualification retry. The trusted PS
# caller owns the exact unnamed JOB_LIST job before this bridge can execute.
STANDALONE_KEYS = {"schema", "architecture", "label", "arguments", "exitCode", "originalPid", "startedUTC",
                   "endedUTC", "executable", "expectedSHA256", "powershell", "powershellSHA256", "parentPid",
                   "deadlineTicks", "frequency"}
CDB_LOCATION = r"C:\Program Files (x86)\Windows Kits\10\Debuggers\arm64\cdb.exe"
CDB_SHA256 = "efda8a8d73116ba97189e1bc638d888f41b592fcc1ba11d8a9039ff2a2472a75"
CDB_VERSION = [10, 0, 26100, 6584]
DIAGNOSTIC_MODULES = {"speakwindows": "app", "ntdll": "ntdll", "kernel32": "kernel32", "kernelbase": "kernelbase",
                      "ucrtbase": "ucrtbase", "swiftcore": "swiftCore", "swift_concurrency": "swift_Concurrency",
                      "swiftdispatch": "swiftDispatch"}
STANDALONE_STATUSES = {"unavailable", "deadline", "observed", "no-reproduction", "invalid", "truncated"}
PREPARATION_PHASES = {"app-identity", "host-identity", "scratch-setup", "event-query", "event-project",
                      "cdb-identity", "identity-recheck", "runtime-layout", "runtime-source", "runtime-copy",
                      "runtime-recheck", "cdb-runner", "debugger-project"}


def _retire_preparation_facts(result, budget, preparation):
    if "preparationFacts" not in result["debugger"]:
        return
    try:
        facts = result["debugger"]["preparationFacts"]
        early = {"app-identity", "host-identity", "scratch-setup"}
        cleanup = (result["cleanup"] == "not-started" and result["applicationError"]["status"] == "unavailable") \
            if facts.get("lastPhase") in early else result["cleanup"] == "clean"
        if type(facts) is not dict or set(facts) != {"lastPhase", "errorCategory"} or \
                type(facts["lastPhase"]) is not str or facts["lastPhase"] not in PREPARATION_PHASES or \
                type(facts["errorCategory"]) is not str or \
                facts["errorCategory"] not in {"validation", "filesystem", "unexpected", "returned-unavailable"} or \
                (facts["errorCategory"] == "returned-unavailable" and facts["lastPhase"] != "cdb-runner") or \
                not cleanup or result["status"] != "unavailable" or result["debugger"]["status"] != "unavailable" or \
                result["debugger"]["exceptionCode"] is not None or result["debugger"]["frames"] or \
                "refusalFacts" in result["debugger"] or not preparation.get("eligible", True) or budget.remaining() <= 2:
            result["debugger"].pop("preparationFacts", None)
    except Exception:
        result["debugger"].pop("preparationFacts", None)


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
    preparation = None
    try:
        request = diagnostic_request(encoded)
        api = api_factory()
        budget = DiagnosticBudget(request, api)
        if not api.admitted(request):
            return result
        result = diagnostic_result()
        preparation = {"lastPhase": "app-identity"}
        budget._diagnostic_preparation = preparation
        app = identity(request["executable"], request["expectedSHA256"], 128 << 20, budget)
        diagnostic_preparation_phase(budget, "host-identity")
        host = identity(request["powershell"], request["powershellSHA256"], 32 << 20, budget)
        # Only fixed system/temp variables; no inherited OP/API/symbol/debugger configuration.
        diagnostic_preparation_phase(budget, "scratch-setup")
        scratch = tempfile.TemporaryDirectory(prefix="jsti-owned-diagnostic-")
        with scratch as directory:
            environment = {key: os.environ[key] for key in ("SystemRoot", "WINDIR") if key in os.environ}
            environment.update(PATH=ntpath.join(environment.get("SystemRoot", r"C:\Windows"), "System32"),
                               TEMP=directory, TMP=directory, USERPROFILE=directory, HOME=directory,
                               APPDATA=directory, LOCALAPPDATA=directory)
            if budget.remaining() >= 7:
                env = dict(environment, JSTI_EVENT_START=request["startedUTC"], JSTI_EVENT_END=request["endedUTC"])
                diagnostic_preparation_phase(budget, "event-query")
                event = runner([request["powershell"], "-NoLogo", "-NoProfile", "-NonInteractive", "-Command",
                                APPLICATION_ERROR_QUERY], env, directory, budget, 5, line_limit=65536)
                result["cleanup"] = event["cleanup"]
                if event["status"] not in ("complete", "unavailable"):
                    preparation["eligible"] = False
                if event["cleanup"] == "failed":
                    return result
                diagnostic_preparation_phase(budget, "event-project")
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
            diagnostic_preparation_phase(budget, "cdb-identity")
            identity(CDB_LOCATION, CDB_SHA256, 32 << 20, budget, version=CDB_VERSION)
            # Recheck the caller-admitted images after optional Event1000 work.
            diagnostic_preparation_phase(budget, "identity-recheck")
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
            diagnostic_preparation_phase(budget, "cdb-runner")
            observed = runner(argv, debugger_environment, directory, budget, min(20, budget.remaining() - 2))
            result["cleanup"] = observed["cleanup"]
            if observed["cleanup"] == "failed":
                return result
            if observed["status"] != "complete":
                status = observed["status"] if observed["status"] in STANDALONE_STATUSES else "unavailable"
                result["status"] = result["debugger"]["status"] = status
                if observed["status"] == "unavailable":
                    result["debugger"]["preparationFacts"] = {"lastPhase": "cdb-runner",
                                                               "errorCategory": "returned-unavailable"}
                return result
            code = observed["exitCode"]
            completion = "zero" if type(code) is int and code == 0 else "nonzero" if type(code) is int else "unknown"
            diagnostic_preparation_phase(budget, "debugger-project")
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
    except Exception as error:
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
        if preparation is not None:
            category = "validation" if isinstance(error, (ValueError, TypeError, KeyError, UnicodeError)) else \
                "filesystem" if isinstance(error, OSError) else "unexpected"
            result["debugger"]["preparationFacts"] = {"lastPhase": preparation["lastPhase"], "errorCategory": category}
    finally:
        # Optional facts are retired after context cleanup, including existing early returns.
        if preparation is not None:
            _retire_preparation_facts(result, budget, preparation)
    # Late cleanup/cutoff cannot leave parser facts looking current. This adds
    # no status, retry, budget or acceptance change to the original operation.
    if "refusalFacts" in result["debugger"]:
        try:
            if result["cleanup"] != "clean" or result["status"] != "invalid" or budget.remaining() <= 2:
                result["debugger"].pop("refusalFacts", None)
        except Exception:
            result["debugger"].pop("refusalFacts", None)
    return result


def standalone_main(argv):
    result = diagnostic_result("invalid")
    if len(argv) == 3 and argv[1] == "--request":
        result = standalone_diagnostic(argv[2])
    serialized = json.dumps(result, separators=(",", ":"), ensure_ascii=True)
    if len(serialized.encode("ascii")) > 8192:
        serialized = json.dumps(diagnostic_result("invalid"), separators=(",", ":"))
    print(serialized)
