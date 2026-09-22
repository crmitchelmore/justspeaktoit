#!/usr/bin/env python3
"""Cross-build the real SwiftPM Windows app and tests after the SDK bootstrap.

The prerequisite cache stays private. Output contains only app/test executables,
their SwiftPM resources and build evidence; no SDK or runtime DLL is copied.
"""
import argparse
import importlib.util
import json
import os
import pathlib
import platform
import shutil
import stat
import struct
import subprocess
import sys
import tarfile
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("cross_bootstrap", HERE / "build-foundation-proof.py")
BOOTSTRAP = importlib.util.module_from_spec(SPEC)
sys.dont_write_bytecode = True
SPEC.loader.exec_module(BOOTSTRAP)


def extract_compiler(archive, destination):
    # The complete official LLVM distribution is much larger than this build
    # needs. Stream it once, retaining its native compiler and resource headers.
    destination.mkdir(parents=True, exist_ok=True)
    root = "LLVM-20.1.8-macOS-ARM64"
    programs = {"bin/clang", "bin/clang++", "bin/clang-20", "bin/llvm-ar", "bin/llvm-readobj"}
    with tarfile.open(archive, "r|xz") as source:
        for member in source:
            parts = pathlib.PurePosixPath(member.name).parts
            if not parts or parts[0] != root or ".." in parts:
                raise ValueError("Unexpected LLVM archive destination")
            relative = "/".join(parts[1:])
            selected = relative in programs or relative == "LICENSE.TXT" or relative.startswith(
                ("lib/clang/", "lib/libclang", "lib/libLLVM", "share/doc/", "share/licenses/"))
            if not selected:
                continue
            if member.issym() or member.islnk():
                target = pathlib.PurePosixPath(member.linkname)
                if target.is_absolute() or ".." in target.parts:
                    raise ValueError("Unexpected LLVM link target")
            if not (member.isfile() or member.isdir() or member.issym() or member.islnk()):
                raise ValueError("Unexpected LLVM archive entry")
            source.extract(member, destination)
    return destination / root / "bin"


def run_package_build(command, environment, log, package):
    # SwiftPM removes Package.resolved for our dependency-free Windows graph.
    # Preserve the caller's exact Apple pins, including uncommitted edits, on
    # success and failure. Never replace them with a repository revision.
    lockfile = package / "Package.resolved"
    try:
        original = lockfile.lstat()
    except FileNotFoundError:
        original = None
    if original is not None and not stat.S_ISREG(original.st_mode):
        raise ValueError("Package.resolved must be a regular file for an in-place cross-build")
    contents = lockfile.read_bytes() if original is not None else None
    try:
        with log.open("a") as stream:
            stream.write("\nARGV: " + json.dumps([str(value) for value in command]) + "\n")
            stream.flush()
            subprocess.run([str(value) for value in command], env=environment, stdout=stream,
                           stderr=subprocess.STDOUT, check=True)
    finally:
        if original is None:
            lockfile.unlink(missing_ok=True)
        else:
            descriptor, name = tempfile.mkstemp(prefix=".Package.resolved-cross-", dir=package)
            temporary = pathlib.Path(name)
            try:
                with os.fdopen(descriptor, "wb") as stream:
                    stream.write(contents)
                    stream.flush()
                    os.fchmod(stream.fileno(), stat.S_IMODE(original.st_mode))
                os.replace(temporary, lockfile)
            finally:
                temporary.unlink(missing_ok=True)


def copy_executable(source, destination, clang, log):
    binary = source.read_bytes()
    pe_offset = struct.unpack_from("<I", binary, 0x3c)[0]
    if binary[:2] != b"MZ" or binary[pe_offset:pe_offset + 6] != b"PE\0\0\x64\x86":
        raise ValueError("Expected a Windows x64 executable: " + source.name)
    shutil.copy2(source, destination)
    BOOTSTRAP.run([clang / "llvm-readobj", "--file-headers", "--coff-imports", destination], log)
    return BOOTSTRAP.digest(destination)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache", required=True, type=pathlib.Path)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--configuration", choices=("debug", "release"), default="release")
    args = parser.parse_args()
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise SystemExit("The pinned app compiler requires an Apple Silicon Mac")
    cache, output = args.cache.resolve(), args.output.resolve()
    if cache == output or cache in output.parents or output in cache.parents:
        raise SystemExit("Keep private prerequisites separate from publishable app output")
    output.mkdir(parents=True, exist_ok=True)
    log = output / "macos-app-build.log"
    log.write_text("")
    lock = json.loads((HERE / "dependencies.json").read_text())
    archive = BOOTSTRAP.download(lock["appCompiler"], cache / "downloads")
    print("Extracting the pinned LLVM 20 compiler privately", flush=True)
    clang = extract_compiler(archive, cache / "llvm-20")
    BOOTSTRAP.run([clang / "clang", "--version"], log)
    tool = cache / "macos-package/swift-6.2.3-RELEASE-osx-package.pkg/Payload/usr"
    sdk = next((cache / "swift-windows").rglob("Windows.sdk"))
    microsoft = cache / "microsoft"
    headers = microsoft / "Microsoft.VC.14.44.17.14.CRT.Headers.base/Contents/VC/Tools/MSVC/14.44.35207/include"
    kits = microsoft / "microsoft.windows.sdk.cpp.10.0.26100.1/c/Include/10.0.26100.0"
    scratch = cache / "app-build"
    command = [tool / "bin/swift", "build", "--package-path", HERE.parent.parent,
               "--triple", "x86_64-unknown-windows-msvc", "--sdk", sdk,
               "--scratch-path", scratch, "--configuration", args.configuration, "--jobs", "4"]
    for flag in ["-resource-dir", sdk / "usr/lib/swift", "-tools-directory", tool / "bin", "-use-ld=lld"]:
        command += ["-Xswiftc", flag]
    for directory in [sdk / "usr/include", headers, kits / "ucrt", kits / "um", kits / "shared", kits / "winrt"]:
        command += ["-Xswiftc", "-I", "-Xswiftc", directory, "-Xcc", "-isystem", "-Xcc", directory]
    for flag in ["-D_MT", "-D_DLL", "-fms-compatibility-version=19.44"]:
        command += ["-Xcc", flag]
    libraries = [sdk / "usr/lib/swift/windows/x86_64"]
    for kind in ["Store", "Desktop"]:
        libraries.append(microsoft / ("Microsoft.VC.14.44.17.14.CRT.x64." + kind + ".base") /
                         "Contents/VC/Tools/MSVC/14.44.35207/lib/x64")
    for kind in ["ucrt", "um"]:
        libraries.append(microsoft / "microsoft.windows.sdk.cpp.x64.10.0.26100.1/c" / kind / "x64")
    for name in ["XCTest", "Testing"]:
        modules = sdk.parent.parent / ("Library/" + name + "-6.2.3/usr/lib/swift/windows")
        command += ["-Xswiftc", "-I", "-Xswiftc", modules]
        libraries.append(modules / "x86_64")
    for directory in libraries:
        command += ["-Xlinker", "/libpath:" + str(directory)]
    environment = os.environ.copy()
    environment.update(SPEAK_WINDOWS_TARGET="1", CC=str(clang / "clang"), CXX=str(clang / "clang++"))
    built = scratch / "x86_64-unknown-windows-msvc" / args.configuration
    print("Cross-building the optimised Windows application", flush=True)
    run_package_build(command + ["--product", "SpeakWindows"], environment, log, HERE.parent.parent)
    # Retain the production app before building tests: testable imports must
    # not change the app artifact's optimisation or internal symbol visibility.
    artifacts = {"SpeakWindows.exe": copy_executable(
        built / "SpeakWindows.exe", output / "SpeakWindows.exe", clang, log)}
    print("Cross-building optimised tests with testable imports", flush=True)
    run_package_build(command + ["--build-tests", "-Xswiftc", "-enable-testing"],
                      environment, log, HERE.parent.parent)
    artifacts["SpeakAppPackageTests.exe"] = copy_executable(
        built / "SpeakAppPackageTests.xctest", output / "SpeakAppPackageTests.exe", clang, log)
    for source in built.glob("*.resources"):
        if source.is_dir():
            shutil.copytree(source, output / source.name, dirs_exist_ok=True)
    metadata = {"host": platform.system(), "hostArchitecture": platform.machine(),
                "target": "x86_64-unknown-windows-msvc", "configuration": args.configuration, "appBuiltForTesting": False,
                "sourceCommit": os.environ.get("GITHUB_SHA"),
                "swiftCompiler": subprocess.check_output([tool / "bin/swift", "--version"], text=True).strip(),
                "nativeCompiler": subprocess.check_output([clang / "clang", "--version"], text=True).strip(),
                "executables": artifacts, "dependencies": lock,
                "runtimeStatus": "Windows execution remains required"}
    (output / "app-build-metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print("Windows app and test executables linked; runtime verification is separate", flush=True)


if __name__ == "__main__":
    main()
