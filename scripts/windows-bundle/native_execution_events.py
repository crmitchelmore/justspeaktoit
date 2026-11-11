"""The packaged application-error query: one Event 1000 lookup for a packaged UI smoke crash, with no debugger.

Part of verify-native-execution.py, which owns the command line.
"""
import base64
import datetime
import json
import ntpath
import os
import re
import tempfile

from native_execution_process import (
    DiagnosticBudget, StandaloneWindows, bounded_diagnostic_process, diagnostic_identity
)
from native_execution_run import APPLICATION_ERROR_QUERY, CRASH_CODES, project_application_error
from native_execution_debugger import closed_module, unique_json


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
