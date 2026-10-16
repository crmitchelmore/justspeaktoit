#!/usr/bin/env python3
"""Separate finite cold preparation from unchanged XCTest runtime budgets."""

import argparse
import hashlib
import itertools
import json
import os
from pathlib import Path
import platform
import runpy
import signal
import subprocess
import sys
import time

GATE = runpy.run_path(str(Path(__file__).with_name("run-core-journey-e2e.py")))
UI = runpy.run_path(str(Path(__file__).with_name("verify-core-journey-ui.py")))
BUILD_BUDGET = 600
SETUP_BUDGET = 300
RUNTIME_BUDGET = {"swift": 480, "ui": 600}
RECEIPT_BUDGET = 60


def artifact_directory(kind):
    name = "CORE_JOURNEY_ARTIFACTS_DIR" if kind == "swift" else "CORE_JOURNEY_UI_ARTIFACTS_DIR"
    default = ".artifacts/core-journey-e2e" if kind == "swift" else ".artifacts/core-journey-fixture-ui"
    return Path(os.environ.get(name, default)).resolve()


def checked_output(command, deadline):
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise TimeoutError("Source/product receipt exceeded its 60s budget.")
    return subprocess.check_output(command, text=True, timeout=min(30, remaining)).strip()


def identity(kind, deadline):
    revision = checked_output(["git", "rev-parse", "HEAD"], deadline)
    if len(revision) != 40 or any(c not in "0123456789abcdef" for c in revision):
        raise ValueError("A full checkout revision is required.")
    if os.environ.get("GITHUB_SHA", revision) != revision:
        raise ValueError("The checkout does not match GITHUB_SHA (including the PR merge revision).")
    if checked_output(["git", "status", "--porcelain", "--untracked-files=no"], deadline):
        raise ValueError("Tracked source changed after checkout; refusing stale test products.")
    swift = checked_output(["swift", "--version"], deadline)
    if "Apple Swift" not in swift:
        raise ValueError("Core journey gates require Xcode's Apple Swift toolchain.")
    return {
        "revision": revision,
        "workspace": str(Path.cwd().resolve()),
        "swift": swift,
        "xcode": checked_output(["xcodebuild", "-version"], deadline),
        "sdk": checked_output(["xcrun", "--sdk", "macosx", "--show-sdk-version"], deadline),
        "architecture": platform.machine(),
        "kind": kind,
        "package_resolved": hashlib.sha256(Path("Package.resolved").read_bytes()).hexdigest(),
    }


def products(kind, directory, deadline):
    if kind == "swift":
        root = Path(".build/debug").resolve()
        bundles = sorted(root.glob("*.xctest"))
        if not bundles:
            raise FileNotFoundError("Swift build did not produce XCTest products.")
        resources = list(root.glob("*.bundle"))
        paths = (path for bundle in bundles + resources for path in bundle.rglob("*"))
        libraries = root.glob("*.dylib")
    else:
        root = directory / "DerivedData/Build/Products"
        manifests = list(root.glob("*.xctestrun"))
        if len(manifests) != 1:
            raise ValueError("Expected exactly one current SpeakApp xctestrun manifest.")
        paths = root.rglob("*")
        libraries = ()
    result = {}
    for path in itertools.chain(paths, libraries):
        if time.monotonic() >= deadline:
            raise TimeoutError("Source/product receipt exceeded its 60s budget.")
        if not path.is_file():
            continue
        digest = hashlib.sha256()
        with path.open("rb") as stream:
            while chunk := stream.read(1024 * 1024):
                if time.monotonic() >= deadline:
                    raise TimeoutError("Source/product receipt exceeded its 60s budget.")
                digest.update(chunk)
        result[str(path.resolve())] = {
            "sha256": digest.hexdigest(), "mode": path.stat().st_mode,
        }
    if not result:
        raise ValueError("The prepared test products are empty.")
    return result


def build_command(kind, directory):
    if kind == "swift":
        return ["swift", "build", "--build-tests"]
    return [
        "xcodebuild", "build-for-testing", "-workspace", "Just Speak to It.xcworkspace",
        "-scheme", "SpeakApp", "-configuration", "Debug", "-destination", "platform=macOS",
        "-derivedDataPath", str(directory / "DerivedData"),
        *ui_selection(), "-skipPackagePluginValidation",
        'CODE_SIGN_IDENTITY=-', "DEVELOPMENT_TEAM=", "CODE_SIGN_STYLE=Manual",
    ]


def ui_selection():
    return [f"-only-testing:SpeakAppUITests/{suite}" for suite in UI["REQUIRED_SUITES"]]


def test_command(kind, directory):
    if kind == "swift":
        return [
            "swift", "test", "--skip-build", "--disable-automatic-resolution",
            "--filter", "|".join(f"{suite}/" for suite in GATE["REQUIRED_SUITES"]),
        ]
    manifests = list((directory / "DerivedData/Build/Products").glob("*.xctestrun"))
    if len(manifests) != 1:
        raise ValueError("The prepared xctestrun manifest is missing or ambiguous.")
    return [
        "xcodebuild", "test-without-building", "-xctestrun", str(manifests[0]),
        "-destination", "platform=macOS", *ui_selection(),
        "-resultBundlePath", str(directory / "CoreJourneyFixture.xcresult"),
        "-disableAutomaticPackageResolution", "-skipPackageUpdates",
        "-skipPackagePluginValidation", "CODE_SIGN_IDENTITY=-",
        "DEVELOPMENT_TEAM=", "CODE_SIGN_STYLE=Manual",
    ]


def prepare(kind, directory):
    receipt = directory / "prepared.json"
    receipt.unlink(missing_ok=True)
    before = identity(kind, time.monotonic() + RECEIPT_BUDGET)
    (directory / "source.json").write_text(json.dumps(before, indent=2) + "\n", encoding="utf-8")
    command = build_command(kind, directory)
    code = GATE["run_gate"](command, directory / "build", BUILD_BUDGET, (), stage="build")
    if code:
        return code
    deadline = time.monotonic() + RECEIPT_BUDGET
    after = identity(kind, deadline)
    if before != after:
        raise ValueError("Checkout/toolchain changed during preparation.")
    data = {"identity": after, "command": command, "products": products(kind, directory, deadline)}
    receipt.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    return 0


def execute(kind, directory):
    data = json.loads((directory / "prepared.json").read_text(encoding="utf-8"))
    deadline = time.monotonic() + RECEIPT_BUDGET
    current = {
        "identity": identity(kind, deadline),
        "command": build_command(kind, directory),
        "products": products(kind, directory, deadline),
    }
    if data != current:
        raise ValueError("Prepared products do not match the current source, toolchain or build options.")
    suites = GATE["REQUIRED_SUITES"] if kind == "swift" else UI["REQUIRED_SUITES"]
    code = GATE["run_gate"](
        test_command(kind, directory), directory / "runtime", RUNTIME_BUDGET[kind], suites
    )
    if kind == "ui":
        # Preserve the existing coverage.json contract as well as stage result.json.
        log = directory / "runtime/test.log"
        if log.exists():
            errors, counts = GATE["coverage_errors"](log.read_text(encoding="utf-8", errors="replace"), suites)
            if code:
                errors.append(f"UI runtime failed with status {code}; see runtime/result.json.")
            (directory / "coverage.json").write_text(
                json.dumps({
                    "required_suites": suites, "counts": counts, "errors": errors, "exit_code": code,
                }, indent=2) + "\n",
                encoding="utf-8",
            )
    return code


def setup(directory):
    return GATE["run_gate"](
        ["bash", "-c", "set -euo pipefail; brew install tuist; tuist generate --no-open"],
        directory / "setup", SETUP_BUDGET, (), stage="setup",
    )


def main(arguments=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("kind", choices=["swift", "ui"])
    parser.add_argument("--phase", choices=["all", "setup", "build", "test"], default="all")
    args = parser.parse_args(arguments)
    directory = artifact_directory(args.kind)
    try:
        directory.mkdir(parents=True, exist_ok=True)
        if args.phase == "setup":
            if args.kind != "ui":
                raise ValueError("Only the UI gate needs Tuist setup.")
            return setup(directory)
        if args.phase == "all" and args.kind == "ui":
            code = setup(directory)
            if code:
                return code
        if args.phase in ("all", "build"):
            code = prepare(args.kind, directory)
            if code or args.phase == "build":
                return code
        return execute(args.kind, directory)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        message = f"{args.kind} {args.phase} failed closed: {error}"
        print(message, file=sys.stderr)
        try:
            (directory / f"{args.phase}-error.json").write_text(
                json.dumps({"exit_code": 1, "phase": args.phase, "error": message}) + "\n", encoding="utf-8"
            )
        except OSError as artifact_error:
            print(f"Could not write failure receipt: {artifact_error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    def interrupted(signum, _frame):
        raise InterruptedError(f"Core journey stage interrupted by signal {signum}")

    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    sys.exit(main())
