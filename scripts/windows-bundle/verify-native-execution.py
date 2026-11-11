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
import json
import os
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
sys.dont_write_bytecode = True
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))
# This file owns the command line. Each phase lives in a sibling module:
#   native_execution_host      host and image evidence, the evidence file
#   native_execution_run       run: launch, observe and assess one program
#   native_execution_process   bounded diagnostic children and their deadline budget
#   native_execution_runtime   the pinned Swift runtime a diagnostic copies
#   native_execution_debugger  standalone-diagnostic: the failure-only CDB run
#   native_execution_events    packaged-application-error: one Event 1000 query
import windows_pe  # noqa: E402
import windows_targets  # noqa: E402
from native_execution_debugger import standalone_main  # noqa: E402
from native_execution_events import packaged_event_main  # noqa: E402
from native_execution_host import ExecutionError, WindowsAPI, check_host, check_images, load_evidence, save_evidence  # noqa: E402
from native_execution_run import run  # noqa: E402


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
        raise SystemExit("native execution: " + str(error)) from error
