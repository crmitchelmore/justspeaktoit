#!/usr/bin/env python3
"""Cross-compile Foundation on macOS using private, hash-pinned prerequisites.

No installers, installer custom actions, shell startup files or global SDK
registries are changed. The cache contains SDK/MSVC files and must stay private.
Only the output directory is suitable for uploading as a build artifact.
"""
import argparse
import concurrent.futures
import hashlib
import json
import mmap
import os
import pathlib
import platform
import shutil
import struct
import subprocess
import sys
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
import zipfile

HERE = pathlib.Path(__file__).resolve().parent


def digest(path, algorithm="sha256"):
    with path.open("rb") as stream:
        hasher = hashlib.new(algorithm)
        while chunk := stream.read(1024 * 1024):
            hasher.update(chunk)
        return hasher.hexdigest()


def download(entry, directory):
    url = urllib.parse.urlsplit(entry["url"])
    if url.scheme != "https" or url.hostname not in {
        "download.swift.org", "github.com", "api.nuget.org", "download.visualstudio.microsoft.com"
    }:
        raise ValueError("Unexpected prerequisite source")
    name = entry["name"]
    if pathlib.PurePath(name).name != name:
        raise ValueError("Prerequisite name must be a basename")
    destination = directory / name
    if destination.exists():
        if destination.stat().st_size != entry["bytes"] or digest(destination) != entry["sha256"]:
            raise ValueError("Cached prerequisite checksum mismatch: " + name)
        return destination
    temporary = destination.with_name(destination.name + ".partial")
    print("Downloading pinned prerequisite:", name, flush=True)
    with urllib.request.urlopen(entry["url"], timeout=120) as response, temporary.open("wb") as output:
        count = 0
        while chunk := response.read(1024 * 1024):
            count += len(chunk)
            if count > entry["bytes"]:
                raise ValueError("Prerequisite exceeded pinned byte count: " + name)
            output.write(chunk)
    if temporary.stat().st_size != entry["bytes"] or digest(temporary) != entry["sha256"]:
        raise ValueError("Downloaded prerequisite checksum mismatch: " + name)
    temporary.replace(destination)
    return destination


def run(arguments, log):
    with log.open("a", encoding="utf-8") as output:
        output.write("\nARGV: " + json.dumps([str(value) for value in arguments]) + "\n")
        output.flush()
        subprocess.run([str(value) for value in arguments], stdout=output, stderr=subprocess.STDOUT, check=True)


def extract_zip(path, destination):
    destination.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(path) as archive:
        for item in archive.infolist():
            name = pathlib.PurePosixPath(item.filename)
            if name.is_absolute() or ".." in name.parts or "\\" in item.filename:
                raise ValueError("Unsafe archive destination")
        archive.extractall(destination)


def remove_staging(path, owner):
    """Remove one explicitly named task-owned staging path, never a linked tree."""
    owner = owner.resolve()
    if path.is_symlink() or owner not in path.resolve().parents:
        raise ValueError("Refusing cleanup outside the task-owned cache")
    if path.is_dir():
        shutil.rmtree(path)
    elif path.exists():
        path.unlink()


def remove_windows_staging(workspace):
    # Retain MSI layout/table JSON and the signed bundle's payload manifest for
    # provenance. CABs, opaque payload copies and expanded staging are redundant
    # only after both reconstructed packages passed their exact size checks.
    if workspace.is_symlink():
        raise ValueError("Refusing cleanup of a linked Windows staging directory")
    names = ["payloads.cab", "bootstrap.cab", "payloads", "packages", "rtl.cab-expanded",
             "windows.cab-expanded", "sdk.windows.x64.cab-expanded",
             "sdk.windows.arm64.cab-expanded", "sdk.windows.x86.cab-expanded"]
    for name in names:
        remove_staging(workspace / name, workspace)


def swift_windows(installer, workspace, seven, output, log):
    workspace.mkdir(parents=True, exist_ok=True)
    # These exact offsets belong to the SHA256-pinned Swift 6.2.3 x64 Burn bundle.
    # Check each CAB header before carving; no executable installer code runs.
    with installer.open("rb") as stream, mmap.mmap(stream.fileno(), 0, access=mmap.ACCESS_READ) as data:
        for name, offset, size in [("bootstrap", 1082368, 210134), ("payloads", 1302848, 890210230)]:
            if data[offset:offset + 4] != b"MSCF" or struct.unpack_from("<I", data, offset + 8)[0] != size:
                raise ValueError("Pinned Swift bundle CAB layout changed")
            cabinet = workspace / (name + ".cab")
            if not cabinet.exists():
                with cabinet.open("xb") as target:
                    for start in range(offset, offset + size, 1024 * 1024):
                        target.write(data[start:min(start + 1024 * 1024, offset + size)])
    run([seven, "x", workspace / "bootstrap.cab", "-o" + str(workspace / "bootstrap"),
         "-y", "-bsp0"], log)
    needed = {"windows.msi", "rtl.msi", "rtl.cab", "windows.cab", "sdk.windows.x64.cab",
              "sdk.windows.arm64.cab", "sdk.windows.x86.cab"}
    payloads = [element for element in ET.parse(workspace / "bootstrap/0").iter()
                if element.tag.endswith("Payload") and element.get("FilePath") in needed]
    if {element.get("FilePath") for element in payloads} != needed:
        raise ValueError("Required Swift payload missing")
    raw = workspace / "payloads"
    run([seven, "x", workspace / "payloads.cab", "-o" + str(raw), "-y", "-bsp0"] +
        [element.get("SourcePath") for element in payloads], log)
    packages = workspace / "packages"
    packages.mkdir(exist_ok=True)
    for element in payloads:
        source = raw / element.get("SourcePath")
        if source.stat().st_size != int(element.get("FileSize")) or digest(source, "sha512") != element.get("Hash").lower():
            raise ValueError("Swift embedded payload checksum mismatch")
        shutil.copy2(source, packages / element.get("FilePath"))
    for name in ["windows", "rtl"]:
        run([sys.executable, HERE / "extract-msi.py", name, "--workspace", workspace,
             "--seven", seven, "--output", output], log)
    remove_windows_staging(workspace)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache", required=True, type=pathlib.Path)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    args = parser.parse_args()
    if platform.system() != "Darwin":
        raise SystemExit("This proof must be compiled on macOS")
    cache, output = args.cache.resolve(), args.output.resolve()
    if cache == output or cache in output.parents or output in cache.parents:
        raise SystemExit("Keep private prerequisite cache separate from publishable proof output")
    cache.mkdir(parents=True, exist_ok=True)
    output.mkdir(parents=True, exist_ok=True)
    log = output / "macos-cross-build.log"
    log.write_text("", encoding="utf-8")
    lock = json.loads((HERE / "dependencies.json").read_text(encoding="utf-8"))
    downloads = cache / "downloads"
    downloads.mkdir(exist_ok=True)
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        list(pool.map(lambda entry: download(entry, downloads), lock["downloads"]))
    print("All prerequisite hashes verified; extracting private SDKs", flush=True)
    seven_root = cache / "sevenzip"
    seven_root.mkdir(exist_ok=True)
    run(["tar", "-xf", downloads / "7z2603-mac.tar.xz", "-C", seven_root], log)
    seven = seven_root / "7zz"
    remove_staging(downloads / "7z2603-mac.tar.xz", cache)
    run(["pkgutil", "--check-signature", downloads / "swift-6.2.3-RELEASE-osx.pkg"], log)
    mac_package = cache / "macos-package"
    if not mac_package.exists():
        run(["pkgutil", "--expand-full", downloads / "swift-6.2.3-RELEASE-osx.pkg", mac_package], log)
    tool = mac_package / "swift-6.2.3-RELEASE-osx-package.pkg/Payload/usr"
    run([tool / "bin/swiftc", "--version"], log)
    # The verified package is ~1.7 GB; retain the expanded compiler and notices,
    # not a second copy, before opening the Windows bundle or LLVM archive.
    remove_staging(downloads / "swift-6.2.3-RELEASE-osx.pkg", cache)
    swift_layout = cache / "swift-windows"
    swift_windows(downloads / "swift-6.2.3-RELEASE-windows10.exe", cache / "windows-extraction",
                  seven, swift_layout, log)
    remove_staging(downloads / "swift-6.2.3-RELEASE-windows10.exe", cache)
    sdk = next(swift_layout.rglob("Windows.sdk"))
    microsoft = cache / "microsoft"
    for entry in lock["downloads"]:
        if entry["name"].endswith((".nupkg", ".vsix")):
            extract_zip(downloads / entry["name"], microsoft / pathlib.Path(entry["name"]).stem)
            remove_staging(downloads / entry["name"], cache)
    headers = microsoft / "Microsoft.VC.14.44.17.14.CRT.Headers.base/Contents/VC/Tools/MSVC/14.44.35207/include"
    kits = microsoft / "microsoft.windows.sdk.cpp.10.0.26100.1/c/Include/10.0.26100.0"
    # Swift's installer places these unmodified maps beside the Microsoft headers.
    for name, directory in [("vcruntime", headers), ("ucrt", kits / "ucrt"), ("winsdk", kits / "um")]:
        shutil.copy2(sdk / ("usr/share/" + name + ".modulemap"), directory / "module.modulemap")
    resource = sdk / "usr/lib/swift/clang"
    if not resource.exists():
        resource.symlink_to(tool / "lib/clang/17")
    command = [tool / "bin/swiftc", "-target", "x86_64-unknown-windows-msvc", "-sdk", sdk,
               "-resource-dir", sdk / "usr/lib/swift", "-module-cache-path", cache / "module-cache"]
    # Swift -I is required: -Xcc -isystem is lost when nested Swift interfaces rebuild.
    for directory in [sdk / "usr/include", headers, kits / "ucrt", kits / "um", kits / "shared", kits / "winrt"]:
        command += ["-I", directory]
    command += ["-Xcc", "-D_MT", "-Xcc", "-D_DLL", "-emit-executable", HERE / "FoundationWindowsProof.swift",
                "-o", output / "FoundationWindowsProof.exe", "-use-ld=lld", "-tools-directory", tool / "bin"]
    libraries = [sdk / "usr/lib/swift/windows/x86_64"]
    for kind in ["Store", "Desktop"]:
        libraries.append(microsoft / ("Microsoft.VC.14.44.17.14.CRT.x64." + kind + ".base") /
                         "Contents/VC/Tools/MSVC/14.44.35207/lib/x64")
    for kind in ["ucrt", "um"]:
        libraries.append(microsoft / "microsoft.windows.sdk.cpp.x64.10.0.26100.1/c" / kind / "x64")
    for directory in libraries:
        command += ["-L", directory]
    print("Compiling and linking Foundation for Windows x64", flush=True)
    run(command, log)
    executable = output / "FoundationWindowsProof.exe"
    run(["file", executable], log)
    proof = executable.read_bytes()
    pe_offset = struct.unpack_from("<I", proof, 0x3c)[0]
    if proof[:2] != b"MZ" or proof[pe_offset:pe_offset + 6] != b"PE\0\0\x64\x86":
        raise ValueError("Cross compiler did not produce a Windows x64 PE")
    compiler = subprocess.check_output([tool / "bin/swiftc", "--version"], text=True).strip()
    metadata = {"host": platform.system(), "hostArchitecture": platform.machine(), "compiler": compiler,
                "sourceCommit": os.environ.get("GITHUB_SHA"),
                "target": "x86_64-unknown-windows-msvc", "executableSHA256": digest(executable),
                "sourceSHA256": digest(HERE / "FoundationWindowsProof.swift"), "dependencies": lock,
                "runtimeStatus": "Not run on macOS; Windows job must execute assertions"}
    (output / "build-metadata.json").write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
    shutil.copy2(HERE / "FoundationWindowsProof.swift", output / "FoundationWindowsProof.swift")
    print("Windows Foundation PE linked:", metadata["executableSHA256"], flush=True)


if __name__ == "__main__":
    main()
