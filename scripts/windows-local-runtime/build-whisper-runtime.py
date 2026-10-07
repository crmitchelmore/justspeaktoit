#!/usr/bin/env python3
"""Build the pinned whisper.cpp runtime DLLs for the Windows app on a Windows runner.

For the requested architecture, installs its pinned Vulkan SDK if it has one
(build-time only), enters its Visual Studio developer environment if it needs
one, checks out the pinned whisper.cpp commit, configures it with that
architecture's pinned CMake arguments, builds the shared libraries and writes
``<output>/runtime`` (the DLLs and licence), ``<output>/fixtures`` (the
upstream JFK sample for CI) and ``<output>/runtime-manifest.json`` recording
every DLL's size, SHA-256, image architecture and imports, the compiler and
the pins. Nothing here runs on a user's machine.
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

# The Visual Studio component each developer environment needs, for vswhere.
DEVELOPER_COMPONENTS = {"arm64": "Microsoft.VisualStudio.Component.VC.Tools.ARM64"}


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


def architecture_pins(pins, architecture):
    """The build pins of one architecture: its SDK, CMake arguments and expected modules."""
    try:
        return pins["architectures"][architecture]
    except KeyError:
        raise RuntimeError_("no whisper.cpp runtime is pinned for %r" % (architecture,)) from None


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
    # sdk.lunarg.com refuses urllib's default User-Agent with 403; the bytes are pinned by SHA-256 either way.
    request = urllib.request.Request(entry["url"], headers={"User-Agent": "justspeaktoit-windows-runtime-build/1"})
    with urllib.request.urlopen(request, timeout=300) as response, partial.open("wb") as output:
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


def install_vulkan_sdk(sdk, downloads, root):
    installer = download(sdk, downloads)
    target = root / sdk["version"]
    if not (target / "Include" / "vulkan" / "vulkan.h").exists():
        run([installer, "--root", target, "--accept-licenses", "--default-answer", "--confirm-command", "install"])
    glslc = target / "Bin" / "glslc.exe"
    if not glslc.exists():
        raise RuntimeError_("the Vulkan SDK did not install glslc")
    return target


def parse_environment(text):
    """Variables from ``set`` output; lines that are not NAME=value are ignored."""
    environment = {}
    for line in text.splitlines():
        name, separator, value = line.partition("=")
        if separator and name and not name.startswith("="):
            environment[name] = value
    return environment


def developer_environment(kind, base):
    """``base`` inside the Visual Studio developer environment for ``kind`` (a vcvarsall target).

    Upstream's ARM64 recipe runs CMake from this environment so clang finds the
    ARM64 MSVC libraries, the Windows SDK and the linker.
    """
    if kind is None:
        return dict(base)
    if kind not in DEVELOPER_COMPONENTS:
        raise RuntimeError_("unknown developer environment %r" % (kind,))
    program_files = base.get("ProgramFiles(x86)") or os.environ.get("ProgramFiles(x86)") or r"C:\Program Files (x86)"
    vswhere = pathlib.Path(program_files) / "Microsoft Visual Studio" / "Installer" / "vswhere.exe"
    installation = subprocess.run([str(vswhere), "-latest", "-products", "*", "-requires", DEVELOPER_COMPONENTS[kind],
                                   "-property", "installationPath"], check=True, capture_output=True,
                                  text=True).stdout.strip()
    vcvarsall = pathlib.Path(installation) / "VC" / "Auxiliary" / "Build" / "vcvarsall.bat"
    if not installation or not vcvarsall.is_file():
        raise RuntimeError_("Visual Studio with " + DEVELOPER_COMPONENTS[kind] + " is not installed")
    # A string command line reaches cmd unchanged; /s strips only the outer quotes.
    command = 'cmd.exe /d /s /c ""%s" %s >nul 2>&1 && set"' % (vcvarsall, kind)
    print("+ " + command, flush=True)
    result = subprocess.run(command, env=dict(base), check=True, capture_output=True, text=True, errors="replace")
    environment = parse_environment(result.stdout)
    if environment.get("VSCMD_ARG_TGT_ARCH", "").lower() != kind:
        raise RuntimeError_("vcvarsall did not enter the %s developer environment" % kind)
    return environment


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


def classify_imports(name, data, runtime_names, policy, architecture="x64"):
    """Return the DLL's imports and refuse any a user's PC could not satisfy.

    The DLL must also be an image a native ``architecture`` process loads, so
    an x64 or ARM64EC build can never be published as the ARM64 runtime.
    """
    image = windows_pe.PEImage(data, name)
    if not image.runs_natively_on(architecture) or not image.is_dll:
        raise RuntimeError_("%s is not a native %s DLL (it is %s)" % (name, architecture, image.architecture))
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


def pinned_vulkan_sdk(target):
    """The Vulkan SDK identity a runtime manifest records; None for a CPU-only architecture."""
    sdk = target["vulkanSdk"]
    return None if sdk is None else {key: sdk[key] for key in ("version", "sha256", "bytes")}


def is_cpu_variant(target, name):
    pattern = target["cpuVariantPattern"]
    return pattern is not None and re.match(pattern, name) is not None


def collect(target, policy, binaries, architecture="x64"):
    names = sorted(path.name for path in binaries.glob("*.dll"))
    expected = [name for name in names if name in target["requiredModules"] or is_cpu_variant(target, name)]
    missing = sorted(set(target["requiredModules"]) - set(names))
    if missing:
        raise RuntimeError_("the build did not produce " + ", ".join(missing))
    if sum(1 for name in expected if is_cpu_variant(target, name)) < target["minimumCpuVariants"]:
        raise RuntimeError_("the build produced too few CPU backend variants")
    files = []
    for name in expected:
        data = (binaries / name).read_bytes()
        static, delayed = classify_imports(name, data, expected, policy, architecture)
        image = windows_pe.PEImage(data, name)
        info = image.version_info() or {}
        files.append({"name": name, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest(),
                      "architecture": image.architecture, "imports": static, "delayImports": delayed,
                      "fileVersion": info.get("fileVersion")})
    return files


def compiler_version(build):
    """The C++ compiler CMake selected and its path, read from its generated description."""
    for description in sorted(build.glob("CMakeFiles/*/CMakeCXXCompiler.cmake")):
        text = description.read_text(encoding="utf-8", errors="replace")
        identity = re.search(r'set\(CMAKE_CXX_COMPILER_ID "([^"]*)"\)', text)
        version = re.search(r'set\(CMAKE_CXX_COMPILER_VERSION "([^"]*)"\)', text)
        path = re.search(r'set\(CMAKE_CXX_COMPILER "([^"]*)"\)', text)
        if identity and version:
            return identity.group(1) + " " + version.group(1), path.group(1) if path else None
    return None, None


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--work", required=True, type=pathlib.Path, help="private scratch directory")
    parser.add_argument("--jobs", type=int, default=os.cpu_count() or 4)
    parser.add_argument("--architecture", default="x64", help="pinned architecture to build (default: x64)")
    args = parser.parse_args(argv)
    if os.name != "nt":
        raise SystemExit("build-whisper-runtime.py builds Windows DLLs and runs on Windows only")
    pins, policy = load_pins(), load_policy()
    target = architecture_pins(pins, args.architecture)
    work, output = args.work.resolve(), args.output.resolve()
    if output.exists():
        shutil.rmtree(output)
    environment = developer_environment(target["developerEnvironment"], os.environ)
    sdk = None
    if target["vulkanSdk"] is not None:
        sdk = install_vulkan_sdk(target["vulkanSdk"], work / "downloads", work / "VulkanSDK")
        environment["VULKAN_SDK"] = str(sdk)
        environment["PATH"] = str(sdk / "Bin") + os.pathsep + environment.get("PATH", "")
    source = work / "whisper.cpp"
    commit = checkout(pins, source)
    license_path = source / "LICENSE"
    if digest(license_path) != pins["whisperCpp"]["licenseSHA256"]:
        raise RuntimeError_("the whisper.cpp licence differs from the pinned text")
    fixture = pins["whisperCpp"]["fixture"]
    if digest(source / fixture["path"]) != fixture["sha256"]:
        raise RuntimeError_("the JFK fixture differs from its pin")
    build = work / "build"
    run(["cmake", "-S", source, "-B", build] + target["cmakeArguments"], env=environment)
    run(["cmake", "--build", build, "--config", "Release", "--parallel", str(args.jobs)], env=environment)
    binaries = build / "bin" / "Release"
    files = collect(target, policy, binaries, args.architecture)
    compiler, compiler_path = compiler_version(build)
    runtime = output / "runtime"
    runtime.mkdir(parents=True)
    for row in files:
        shutil.copy2(binaries / row["name"], runtime / row["name"])
    shutil.copy2(license_path, runtime / "LICENSE-whisper.cpp.txt")
    fixtures = output / "fixtures"
    fixtures.mkdir()
    shutil.copy2(source / fixture["path"], fixtures / "jfk.wav")
    manifest = {
        "schemaVersion": 2,
        "runtime": "whisper.cpp",
        "architecture": args.architecture,
        "version": pins["whisperCpp"]["version"],
        "commit": commit,
        "repository": pins["whisperCpp"]["repository"],
        "cmakeArguments": target["cmakeArguments"],
        "vulkanSdk": pinned_vulkan_sdk(target),
        "compiler": compiler,
        "compilerPath": compiler_path,
        "license": {"name": "LICENSE-whisper.cpp.txt", "sha256": pins["whisperCpp"]["licenseSHA256"],
                    "spdx": pins["whisperCpp"]["license"]},
        "files": files,
        "fixtures": [{"name": "jfk.wav", "sha256": fixture["sha256"], "bytes": fixture["bytes"],
                      "expectedPhrase": fixture["expectedPhrase"]}],
        "pinsSHA256": pins_digest(HERE / "dependencies.json"),
    }
    (output / "runtime-manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n",
                                                  encoding="utf-8")
    print("Built %d %s whisper.cpp runtime DLLs at %s with %s" % (len(files), args.architecture, commit, compiler))
    for row in files:
        print("  %-28s %-8s %10d  %s" % (row["name"], row["architecture"], row["bytes"], row["sha256"]))


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError_, windows_pe.PEFormatError, subprocess.CalledProcessError) as error:
        raise SystemExit("whisper runtime: " + str(error))
