#!/usr/bin/env python3
"""Build a pinned native CPU llama.cpp runtime from an existing clean source checkout.

No network/download/install is performed. Run on the intended Windows or Linux
architecture with CMake, Ninja and its native C/C++ toolchain already configured.
The new output directory is the LocalLLMRuntime folder to stage beside the app.
This produces a build manifest, NEVER a native/model-quality qualification receipt.
"""
import argparse
import hashlib
import json
import pathlib
import platform
import shutil
import struct
import subprocess
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
sys.dont_write_bytecode = True
sys.path.insert(0, str(HERE))
import local_llm_package
COMMIT = local_llm_package.COMMIT


def command(*args):
    return subprocess.run(args, check=True, text=True, capture_output=True).stdout.strip()


def authenticate(source):
    if command("git", "-C", str(source), "rev-parse", "HEAD") != COMMIT:
        raise ValueError("llama.cpp source is not the pinned b6500 commit")
    if command("git", "-C", str(source), "status", "--porcelain", "--untracked-files=all"):
        raise ValueError("llama.cpp source must be clean, including untracked files")
    return source


def verify_binary(binary, system, architecture):
    if not 1 <= binary.stat().st_size <= 536_870_912:
        raise ValueError("native runtime exceeds its package size bound")
    if system == "windows":
        sys.path.insert(0, str(HERE.parent / "windows-bundle"))
        import windows_pe
        image = windows_pe.PEImage.load(binary)
        expected = "x64" if architecture == "x86_64" else "arm64"
        if image.architecture != expected or not image.characteristics & 0x2000:
            raise ValueError("compiler produced a foreign-architecture or non-DLL Windows image")
    else:
        with binary.open("rb") as stream:
            header = stream.read(64)
        if len(header) != 64 or header[:7] != b"\x7fELF\x02\x01\x01":
            raise ValueError("compiler did not produce a little-endian ELF64 runtime")
        kind, machine = struct.unpack_from("<HH", header, 16)
        if kind != 3 or machine != (62 if architecture == "x86_64" else 183):
            raise ValueError("compiler produced a foreign-architecture or non-shared Linux image")


def build(source, output, build_directory, generator="Ninja"):
    system = platform.system().lower()
    architecture = {"amd64": "x86_64", "x86_64": "x86_64", "aarch64": "arm64", "arm64": "arm64"}.get(
        platform.machine().lower())
    if system not in ("windows", "linux") or architecture is None:
        raise ValueError("build natively on Windows/Linux x86_64 or arm64")
    source = authenticate(source.resolve(strict=True))
    if output.exists() or build_directory.exists():
        raise ValueError("output and build directories must be new; existing data is never replaced")
    if source in output.resolve().parents or source in build_directory.resolve().parents:
        raise ValueError("build and output directories must be outside the immutable upstream checkout")
    output.parent.mkdir(parents=True, exist_ok=True)
    library = "llama.dll" if system == "windows" else "libllama.so"
    with tempfile.TemporaryDirectory(prefix="jsti-local-llm-", dir=output.parent) as temporary:
        staging = pathlib.Path(temporary) / "LocalLLMRuntime"
        staging.mkdir()
        subprocess.run([
            "cmake", "-S", str(HERE), "-B", str(build_directory), "-G", generator,
            "-DCMAKE_BUILD_TYPE=Release", "-DJSTI_LLAMA_SOURCE=" + str(source),
            "-DCMAKE_INSTALL_PREFIX=" + str(staging)
        ], check=True)
        subprocess.run(["cmake", "--build", str(build_directory), "--config", "Release",
                        "--target", "jsti_llama_runtime"], check=True)
        subprocess.run(["cmake", "--install", str(build_directory), "--config", "Release"], check=True)
        binary = staging / library
        if not binary.is_file() or binary.is_symlink():
            raise ValueError("the monolithic native runtime was not produced")
        if {path.name for path in staging.iterdir()} != {library}:
            raise ValueError("unexpected payload files; only the monolithic runtime is allowed")
        verify_binary(binary, system, architecture)
        with binary.open("rb") as stream:
            digest = hashlib.file_digest(stream, "sha256").hexdigest()
        manifest = {
            "schemaVersion": 1, "commit": COMMIT, "platform": system,
            "architecture": architecture, "library": library, "sha256": digest,
        }
        (staging / "provisioning.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
        shutil.copyfile(source / "LICENSE", staging / "LICENSE.llama-cpp")
        local_llm_package.read_directory(staging, system, architecture)
        staging.rename(output)
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=pathlib.Path)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--build-directory", required=True, type=pathlib.Path)
    parser.add_argument("--generator", default="Ninja")
    args = parser.parse_args()
    print(json.dumps(build(args.source, args.output, args.build_directory, args.generator), indent=2))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit("native local LLM provisioning failed: " + str(error))
