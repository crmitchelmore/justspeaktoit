#!/usr/bin/env python3
"""Build the pinned whisper.cpp runtime DLLs for the Windows app on a Windows runner.

Installs the pinned Vulkan SDK (build-time only), checks out the pinned
whisper.cpp commit, configures it with the pinned CMake arguments, builds the
shared libraries and writes ``<output>/runtime`` (the DLLs and licence),
``<output>/fixtures`` (the upstream JFK sample for CI) and
``<output>/runtime-manifest.json`` recording every DLL's size, SHA-256 and
imports, the compiler and the pins. Nothing here runs on a user's machine.
"""
import argparse
import hashlib
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import urllib.request

HERE = pathlib.Path(__file__).resolve().parent
sys.dont_write_bytecode = True
sys.path.insert(0, str(HERE.parent / "windows-bundle"))
import windows_pe  # noqa: E402


class RuntimeError_(Exception):
    """The runtime does not match its pins; nothing is published."""


def digest(path):
    hasher = hashlib.sha256()
    with pathlib.Path(path).open("rb") as stream:
        while chunk := stream.read(1 << 20):
            hasher.update(chunk)
    return hasher.hexdigest()


def pins_digest(path):
    """SHA-256 of the pin file with LF line endings, so Windows (CRLF) and macOS checkouts agree."""
    return hashlib.sha256(pathlib.Path(path).read_bytes().replace(b"\r\n", b"\n")).hexdigest()


def load_pins(path=HERE / "dependencies.json"):
    return json.loads(pathlib.Path(path).read_text(encoding="utf-8"))


def load_policy():
    return json.loads((HERE.parent / "windows-bundle" / "runtime-policy.json").read_text(encoding="utf-8"))


def run(command, **kwargs):
    print("+ " + " ".join(str(part) for part in command), flush=True)
    subprocess.run([str(part) for part in command], check=True, **kwargs)


def download(entry, directory):
    directory.mkdir(parents=True, exist_ok=True)
    destination = directory / entry["name"]
    if destination.exists() and destination.stat().st_size == entry["bytes"] and digest(destination) == entry["sha256"]:
        return destination
    partial = destination.with_name(entry["name"] + ".partial")
    with urllib.request.urlopen(entry["url"], timeout=300) as response, partial.open("wb") as output:
        count = 0
        while chunk := response.read(1 << 20):
            count += len(chunk)
            if count > entry["bytes"]:
                raise RuntimeError_("download exceeded its pinned size: " + entry["name"])
            output.write(chunk)
    if partial.stat().st_size != entry["bytes"] or digest(partial) != entry["sha256"]:
        partial.unlink()
        raise RuntimeError_("download does not match its pinned SHA-256: " + entry["name"])
    partial.replace(destination)
    return destination


def install_vulkan_sdk(pins, downloads, root):
    sdk = pins["vulkanSdk"]
    installer = download(sdk, downloads)
    target = root / sdk["version"]
    if not (target / "Include" / "vulkan" / "vulkan.h").exists():
        run([installer, "--root", target, "--accept-licenses", "--default-answer", "--confirm-command", "install"])
    glslc = target / "Bin" / "glslc.exe"
    if not glslc.exists():
        raise RuntimeError_("the Vulkan SDK did not install glslc")
    return target


def checkout(pins, source):
    whisper = pins["whisperCpp"]
    if not (source / ".git").exists():
        source.mkdir(parents=True, exist_ok=True)
        run(["git", "init", "-q", source])
        run(["git", "-C", source, "remote", "add", "origin", whisper["repository"]])
    # Exact upstream bytes: the licence and fixture digests must not see CRLF conversion.
    run(["git", "-C", source, "config", "core.autocrlf", "false"])
    run(["git", "-C", source, "fetch", "-q", "--depth", "1", "origin", whisper["commit"]])
    run(["git", "-C", source, "checkout", "-q", "--force", "FETCH_HEAD"])
    head = subprocess.run(["git", "-C", str(source), "rev-parse", "HEAD"], check=True, capture_output=True,
                          text=True).stdout.strip()
    if head != whisper["commit"]:
        raise RuntimeError_("whisper.cpp checkout is %s, not the pinned %s" % (head, whisper["commit"]))
    return head


def classify_imports(name, data, runtime_names, pins, policy):
    """Return the DLL's imports and refuse any a user's PC could not satisfy."""
    image = windows_pe.PEImage(data, name)
    if not image.is_x64 or not image.is_dll:
        raise RuntimeError_(name + " is not an x64 DLL")
    static, delayed = image.imports(), image.delay_imports()
    allowed = {module.lower() for module in policy["windowsSystemModules"]}
    allowed |= {module.lower() for module in policy["microsoftRuntimeModules"]}
    allowed |= {module.lower() for module in runtime_names}
    api_sets = [re.compile(pattern) for pattern in policy["windowsApiSetPatterns"]]
    for module in static + delayed:
        lower = module.lower()
        if lower in allowed or any(pattern.match(lower) for pattern in api_sets):
            continue
        raise RuntimeError_("%s imports %s, which is neither a Windows module, the Visual C++ runtime nor part of "
                            "the whisper.cpp runtime" % (name, module))
    return static, delayed


def collect(pins, policy, binaries):
    names = sorted(path.name for path in binaries.glob("*.dll"))
    variant = re.compile(pins["cpuVariantPattern"])
    expected = [name for name in names if name in pins["requiredModules"] or variant.match(name)]
    missing = sorted(set(pins["requiredModules"]) - set(names))
    if missing:
        raise RuntimeError_("the build did not produce " + ", ".join(missing))
    if sum(1 for name in expected if variant.match(name)) < pins["minimumCpuVariants"]:
        raise RuntimeError_("the build produced too few CPU backend variants")
    files = []
    for name in expected:
        data = (binaries / name).read_bytes()
        static, delayed = classify_imports(name, data, expected, pins, policy)
        info = windows_pe.PEImage(data, name).version_info() or {}
        files.append({"name": name, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest(),
                      "imports": static, "delayImports": delayed, "fileVersion": info.get("fileVersion")})
    return files


def compiler_version(build):
    """The C++ compiler CMake selected, read from its generated description."""
    for description in sorted(build.glob("CMakeFiles/*/CMakeCXXCompiler.cmake")):
        text = description.read_text(encoding="utf-8", errors="replace")
        identity = re.search(r'set\(CMAKE_CXX_COMPILER_ID "([^"]*)"\)', text)
        version = re.search(r'set\(CMAKE_CXX_COMPILER_VERSION "([^"]*)"\)', text)
        if identity and version:
            return identity.group(1) + " " + version.group(1)
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--work", required=True, type=pathlib.Path, help="private scratch directory")
    parser.add_argument("--jobs", type=int, default=os.cpu_count() or 4)
    args = parser.parse_args()
    if os.name != "nt":
        raise SystemExit("build-whisper-runtime.py builds Windows DLLs and runs on Windows only")
    pins, policy = load_pins(), load_policy()
    work, output = args.work.resolve(), args.output.resolve()
    if output.exists():
        shutil.rmtree(output)
    sdk = install_vulkan_sdk(pins, work / "downloads", work / "VulkanSDK")
    source = work / "whisper.cpp"
    commit = checkout(pins, source)
    license_path = source / "LICENSE"
    if digest(license_path) != pins["whisperCpp"]["licenseSHA256"]:
        raise RuntimeError_("the whisper.cpp licence differs from the pinned text")
    fixture = pins["whisperCpp"]["fixture"]
    if digest(source / fixture["path"]) != fixture["sha256"]:
        raise RuntimeError_("the JFK fixture differs from its pin")
    build = work / "build"
    environment = dict(os.environ, VULKAN_SDK=str(sdk))
    environment["PATH"] = str(sdk / "Bin") + os.pathsep + environment["PATH"]
    run(["cmake", "-S", source, "-B", build] + pins["cmakeArguments"], env=environment)
    run(["cmake", "--build", build, "--config", "Release", "--parallel", str(args.jobs)], env=environment)
    binaries = build / "bin" / "Release"
    files = collect(pins, policy, binaries)
    runtime = output / "runtime"
    runtime.mkdir(parents=True)
    for row in files:
        shutil.copy2(binaries / row["name"], runtime / row["name"])
    shutil.copy2(license_path, runtime / "LICENSE-whisper.cpp.txt")
    fixtures = output / "fixtures"
    fixtures.mkdir()
    shutil.copy2(source / fixture["path"], fixtures / "jfk.wav")
    manifest = {
        "schemaVersion": 1,
        "runtime": "whisper.cpp",
        "version": pins["whisperCpp"]["version"],
        "commit": commit,
        "repository": pins["whisperCpp"]["repository"],
        "cmakeArguments": pins["cmakeArguments"],
        "vulkanSdk": {key: pins["vulkanSdk"][key] for key in ("version", "sha256", "bytes")},
        "compiler": compiler_version(build),
        "license": {"name": "LICENSE-whisper.cpp.txt", "sha256": pins["whisperCpp"]["licenseSHA256"],
                    "spdx": pins["whisperCpp"]["license"]},
        "files": files,
        "fixtures": [{"name": "jfk.wav", "sha256": fixture["sha256"], "bytes": fixture["bytes"],
                      "expectedPhrase": fixture["expectedPhrase"]}],
        "pinsSHA256": pins_digest(HERE / "dependencies.json"),
    }
    (output / "runtime-manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n",
                                                  encoding="utf-8")
    print("Built %d whisper.cpp runtime DLLs at %s" % (len(files), commit))
    for row in files:
        print("  %-28s %10d  %s" % (row["name"], row["bytes"], row["sha256"]))


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError_, windows_pe.PEFormatError, subprocess.CalledProcessError) as error:
        raise SystemExit("whisper runtime: " + str(error))
