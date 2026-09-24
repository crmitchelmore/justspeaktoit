#!/usr/bin/env python3
"""Build the pinned whisper.cpp runtime libraries for the Linux app.

Reads the whisper.cpp pin (repository, tag, commit, licence digest and JFK
fixture) from ``scripts/windows-local-runtime/dependencies.json``, so the
Windows and Linux runtimes come from one pin, and the Linux build switches from
``dependencies.json`` beside this script. Checks out the pinned commit, builds
the shared libraries with CMake and writes ``<output>/runtime`` (the libraries
under their sonames, and the licence), ``<output>/fixtures`` (the upstream JFK
sample for CI) and ``<output>/runtime-manifest.json`` recording every
library's size, SHA-256, soname and needed libraries, the compiler and the
pins. Nothing here runs on a user's machine.
"""
import argparse
import hashlib
import importlib.util
import json
import os
import pathlib
import platform
import re
import shutil
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent
REPOSITORY = HERE.parent.parent
sys.dont_write_bytecode = True


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# The checkout, digest and compiler helpers are the Windows builder's own, so
# both runtimes verify the pinned commit the same way.
WINDOWS = _load("build_whisper_runtime_windows", HERE.parent / "windows-local-runtime" / "build-whisper-runtime.py")


class RuntimeError_(Exception):
    """The runtime does not match its pins; nothing is published."""


def load_pins(path=HERE / "dependencies.json"):
    return json.loads(pathlib.Path(path).read_text(encoding="utf-8"))


def whisper_pin(pins):
    """The shared whisper.cpp pin, from the file the Linux pins name."""
    return WINDOWS.load_pins(REPOSITORY / pins["whisperCppPin"])["whisperCpp"]


def architecture_pins(pins, architecture):
    try:
        return pins["architectures"][architecture]
    except KeyError:
        raise RuntimeError_("no Linux whisper.cpp runtime is pinned for %r" % (architecture,)) from None


def cmake_arguments(pins, target, vulkan):
    """The pinned CMake switches; ``--vulkan`` replaces GGML_VULKAN=OFF."""
    arguments = list(target["cmakeArguments"])
    if vulkan:
        arguments = [value for value in arguments if not value.startswith("-DGGML_VULKAN=")]
        arguments += pins["vulkan"]["cmakeArguments"]
    return arguments


def expected_modules(pins, target, vulkan):
    return list(target["requiredModules"]) + ([pins["vulkan"]["module"]] if vulkan else [])


def allowed_system_libraries(pins, target, vulkan):
    return set(target["systemLibraries"]) | (set(pins["vulkan"]["systemLibraries"]) if vulkan else set())


def is_cpu_variant(target, name):
    return re.match(target["cpuVariantPattern"], name) is not None


def parse_readelf(text):
    """The fields of ``readelf --wide --file-header --dynamic`` the policy checks."""
    kind = re.search(r"^\s*Type:\s+(\S+)", text, re.M)
    machine = re.search(r"^\s*Machine:\s+(.+?)\s*$", text, re.M)
    soname = re.search(r"\(SONAME\)\s+Library soname: \[([^\]]*)\]", text)
    return {
        "type": kind.group(1) if kind else None,
        "machine": machine.group(1) if machine else None,
        "soname": soname.group(1) if soname else None,
        "needed": re.findall(r"\(NEEDED\)\s+Shared library: \[([^\]]*)\]", text),
        "searchPaths": re.findall(r"\((?:RPATH|RUNPATH)\)\s+Library r(?:un)?path: \[([^\]]*)\]", text),
    }


def readelf(path):
    return subprocess.run(["readelf", "--wide", "--file-header", "--dynamic", str(path)], check=True,
                          capture_output=True, text=True).stdout


def check_library(name, elf, target, runtime_names, system_libraries):
    """Refuse a library a user's computer could not load from the runtime directory alone.

    It must be a shared object for the pinned machine, carry no RPATH or
    RUNPATH (the loader opens its dependencies by absolute path), name itself
    by its file name when it has a soname, and need only the C and C++
    runtimes, the runtime's own libraries and, for Vulkan, the system loader.
    """
    if elf["type"] != "DYN" or elf["machine"] != target["elfMachine"]:
        raise RuntimeError_("%s is not a %s shared object (%s, %s)" % (name, target["elfMachine"], elf["type"],
                                                                        elf["machine"]))
    if elf["searchPaths"]:
        raise RuntimeError_("%s carries a library search path (%s)" % (name, ", ".join(elf["searchPaths"])))
    if elf["soname"] is not None and elf["soname"] != name:
        raise RuntimeError_("%s names itself %s" % (name, elf["soname"]))
    for needed in elf["needed"]:
        if needed not in system_libraries and needed not in runtime_names:
            raise RuntimeError_("%s needs %s, which is neither a system C/C++ runtime library nor part of the "
                                "whisper.cpp runtime" % (name, needed))
    return elf["needed"]


def collect(pins, target, binaries, vulkan, inspect=lambda path: parse_readelf(readelf(path))):
    """The runtime files from the CMake output directory, checked against the pins.

    Required modules are looked up by soname (CMake's symlink to the versioned
    file); CPU backend variants are the ``libggml-cpu-*.so`` modules.
    """
    required = expected_modules(pins, target, vulkan)
    missing = [name for name in required if not (binaries / name).exists()]
    if missing:
        raise RuntimeError_("the build did not produce " + ", ".join(missing))
    variants = sorted(path.name for path in binaries.glob("libggml-cpu-*.so") if is_cpu_variant(target, path.name))
    if len(variants) < target["minimumCpuVariants"]:
        raise RuntimeError_("the build produced too few CPU backend variants (%d)" % len(variants))
    names = required + variants
    system = allowed_system_libraries(pins, target, vulkan)
    files = []
    for name in names:
        source = (binaries / name).resolve()
        data = source.read_bytes()
        needed = check_library(name, inspect(source), target, set(names), system)
        kind = "cpu-backend" if name in variants else ("gpu-backend" if vulkan and name == pins["vulkan"]["module"]
                                                        else "library")
        files.append({"name": name, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest(),
                      "kind": kind, "needed": needed})
    return files


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--work", required=True, type=pathlib.Path, help="private scratch directory")
    parser.add_argument("--jobs", type=int, default=os.cpu_count() or 4)
    parser.add_argument("--architecture", default=platform.machine(),
                        help="pinned architecture to build (default: this machine's)")
    parser.add_argument("--vulkan", action="store_true", help="also build the optional Vulkan backend")
    args = parser.parse_args(argv)
    if not sys.platform.startswith("linux"):
        raise SystemExit("build-whisper-runtime.py builds Linux shared libraries and runs on Linux only")
    pins = load_pins()
    whisper = whisper_pin(pins)
    target = architecture_pins(pins, args.architecture)
    work, output = args.work.resolve(), args.output.resolve()
    if output.exists():
        shutil.rmtree(output)
    source = work / "whisper.cpp"
    commit = WINDOWS.checkout({"whisperCpp": whisper}, source)
    license_path = source / "LICENSE"
    if WINDOWS.digest(license_path) != whisper["licenseSHA256"]:
        raise RuntimeError_("the whisper.cpp licence differs from the pinned text")
    fixture = whisper["fixture"]
    if WINDOWS.digest(source / fixture["path"]) != fixture["sha256"]:
        raise RuntimeError_("the JFK fixture differs from its pin")
    build = work / ("build-vulkan" if args.vulkan else "build")
    arguments = cmake_arguments(pins, target, args.vulkan)
    WINDOWS.run(["cmake", "-S", source, "-B", build] + arguments)
    # Only libwhisper and what it links: the ggml libraries and every CPU
    # backend module (ggml depends on them), not parakeet or the examples.
    WINDOWS.run(["cmake", "--build", build, "--target", "whisper", "--parallel", str(args.jobs)])
    files = collect(pins, target, build / "bin", args.vulkan)
    compiler, compiler_path = WINDOWS.compiler_version(build)
    runtime = output / "runtime"
    runtime.mkdir(parents=True)
    for row in files:
        shutil.copyfile((build / "bin" / row["name"]).resolve(), runtime / row["name"])
        os.chmod(runtime / row["name"], 0o755)
    shutil.copyfile(license_path, runtime / "LICENSE-whisper.cpp.txt")
    fixtures = output / "fixtures"
    fixtures.mkdir()
    shutil.copyfile(source / fixture["path"], fixtures / "jfk.wav")
    manifest = {
        "schemaVersion": 1,
        "runtime": "whisper.cpp",
        "platform": "linux",
        "architecture": args.architecture,
        "version": whisper["version"],
        "commit": commit,
        "repository": whisper["repository"],
        "cmakeArguments": arguments,
        "vulkan": args.vulkan,
        "compiler": compiler,
        "compilerPath": compiler_path,
        "license": {"name": "LICENSE-whisper.cpp.txt", "sha256": whisper["licenseSHA256"],
                    "spdx": whisper["license"]},
        "files": files,
        "fixtures": [{"name": "jfk.wav", "sha256": fixture["sha256"], "bytes": fixture["bytes"],
                      "expectedPhrase": fixture["expectedPhrase"]}],
        "pinsSHA256": WINDOWS.pins_digest(HERE / "dependencies.json"),
        "whisperPinSHA256": WINDOWS.pins_digest(REPOSITORY / pins["whisperCppPin"]),
    }
    (output / "runtime-manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n",
                                                  encoding="utf-8")
    print("Built %d %s whisper.cpp runtime libraries at %s with %s" % (len(files), args.architecture, commit,
                                                                        compiler))
    for row in files:
        print("  %-32s %-12s %10d  %s" % (row["name"], row["kind"], row["bytes"], row["sha256"]))


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError_, WINDOWS.RuntimeError_, subprocess.CalledProcessError) as error:
        raise SystemExit("whisper runtime: " + str(error))
