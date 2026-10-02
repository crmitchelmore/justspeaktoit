#!/usr/bin/env python3
"""Retain a natively built production SpeakWindows.exe and record how it was built.

Run on Windows after ``swift build --configuration release --product
SpeakWindows`` and before any test build, which recompiles the same modules
with testable imports. The output has the layout ``build-windows-app.py``
produces on the Mac: ``SpeakWindows.exe``, its SwiftPM resource directories
and ``app-build-metadata.json``, so the bundle builder authenticates either.
The executable must be an image a native process of the architecture loads
and must not import a test library.
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

HERE = pathlib.Path(__file__).resolve().parent
sys.dont_write_bytecode = True
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))
import windows_pe  # noqa: E402
import windows_targets  # noqa: E402

APPLICATION = "SpeakWindows.exe"
TEST_MODULES = {"xctest.dll", "testing.dll"}


class StageError(Exception):
    """The build output is not a native production build of this architecture."""


def tool_version(command):
    """First lines of ``command``'s version output, or None when the tool is unavailable."""
    try:
        result = subprocess.run(command, check=True, capture_output=True, encoding="utf-8", errors="replace")
    except (OSError, subprocess.CalledProcessError):
        return None
    return (result.stdout or result.stderr).strip() or None


def stage(bin_path, output, architecture, commit, versions=None):
    target = windows_targets.target(architecture)
    bin_path, output = pathlib.Path(bin_path).resolve(), pathlib.Path(output).resolve()
    # SwiftPM places a build in <scratch>/<triple>/<configuration>.
    if bin_path.name != "release" or bin_path.parent.name != target["swiftTriple"]:
        raise StageError("%s is not a %s release build directory" % (bin_path, target["swiftTriple"]))
    if output == bin_path or bin_path in output.parents or output in bin_path.parents:
        raise StageError("keep the staged app separate from the build directory")
    if output.exists() and any(output.iterdir()):
        raise StageError("the staging directory must be new or empty")
    executable = bin_path / APPLICATION
    data = executable.read_bytes()
    image = windows_pe.PEImage(data, APPLICATION)
    if not image.runs_natively_on(architecture) or image.is_dll:
        raise StageError("%s is a %s image, not a native %s executable" % (APPLICATION, image.architecture, architecture))
    tests = sorted(name for name in image.imports() + image.delay_imports() if name.lower() in TEST_MODULES)
    if tests:
        raise StageError(APPLICATION + " imports " + ", ".join(tests) + "; stage it before building tests")
    output.mkdir(parents=True, exist_ok=True)
    shutil.copy2(executable, output / APPLICATION)
    resources = []
    for directory in sorted(bin_path.glob("*.resources")):
        if not directory.is_dir() or directory.is_symlink() or directory.name[:-len(".resources")].endswith("Tests"):
            continue
        shutil.copytree(directory, output / directory.name, symlinks=True)
        resources.append(directory.name)
    versions = versions or {"swiftCompiler": tool_version(["swift", "--version"]),
                            "nativeCompiler": tool_version(["clang", "--version"])}
    metadata = {"host": platform.system(), "hostArchitecture": platform.machine(), "target": target["swiftTriple"],
                "configuration": "release", "appBuiltForTesting": False, "sourceCommit": commit,
                "build": "native Windows SwiftPM build, staged before any test build",
                "imageArchitecture": image.architecture,
                "swiftCompiler": versions["swiftCompiler"], "nativeCompiler": versions["nativeCompiler"],
                "executables": {APPLICATION: hashlib.sha256(data).hexdigest()}, "resources": resources,
                "runtimeStatus": "Windows execution evidence is recorded separately"}
    (output / "app-build-metadata.json").write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
    return metadata


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--architecture", required=True, choices=sorted(windows_targets.TARGETS))
    parser.add_argument("--bin-path", required=True, type=pathlib.Path, help="swift build --show-bin-path output")
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--commit", default=os.environ.get("GITHUB_SHA"), help="source commit (default: GITHUB_SHA)")
    args = parser.parse_args(argv)
    metadata = stage(args.bin_path, args.output, args.architecture, args.commit)
    print(json.dumps({key: metadata[key] for key in ("target", "hostArchitecture", "imageArchitecture", "executables")},
                     indent=2, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except (StageError, windows_pe.PEFormatError, OSError, ValueError) as error:
        raise SystemExit("stage native app: " + str(error))
