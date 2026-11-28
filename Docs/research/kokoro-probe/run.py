"""Run inside a disposable x64 hosted runner. Write a CSV per host."""

import base64
import hashlib
import os
import platform
import shutil
import subprocess
from pathlib import Path

root = Path.cwd()
src = root / "Docs/research/kokoro-probe"
win = platform.system() == "Windows"
assert platform.machine().lower() in {"amd64", "x86_64"}
work = Path(os.environ["RUNNER_TEMP"]) / "kokoro"
work.mkdir()
os.chdir(work)
base = "https://github.com/k2-fsa/sherpa-onnx/releases/download/"
version = "v2.0.1"
arch = "win-x64-shared-MD-Release" if win else "osx-x64-shared"
runtime = f"sherpa-onnx-{version}-{arch}-lib"
model = "kokoro-int8-multi-lang-v1_0"


def download(url, name, digest):
    subprocess.run(["curl", "-fsSL", "--retry", "3", url, "-o", name], check=True)
    with open(name, "rb") as stream:
        assert hashlib.file_digest(stream, "sha256").hexdigest() == digest


for tag, name, digest in [
    ("tts-models", model, "72c347230107ef8a31098ec4d468a605244beef5f1ed00db97efa13518800653"),
    (version, runtime, "c3c78220db8bebf97d5f932496165bb3897b163410427d7c021013439c80f183" if win
     else "be9042971c5d1b14da76a960534d2a8cdb6f0e5e02f5e1dc8bddff8576359bdd"),
]:
    archive = name + ".tar.bz2"
    download(base + tag + "/" + archive, archive, digest)
    subprocess.run(["tar", "xf", archive], check=True)

download("https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/af2d8d81dbfa61c4cea4c568da78f3982edca005/sherpa-onnx/c-api/c-api.h",
         "c-api.h", "5698f38ba09ad2bdf085c56a6cbbd7741acf15e25f4ce5c7097b9702cadf437f")
Path("input.h").write_bytes(base64.b64decode(os.environ["INPUT_HEADER"], validate=True))
lib = next(Path(runtime).rglob("sherpa-onnx-c-api.lib" if win else "libsherpa-onnx-c-api.dylib")).resolve()
exe = work / ("bench.exe" if win else "bench")
flags = [str(lib), "-lpsapi"] if win else [str(lib), "-Wl,-rpath," + str(lib.parent)]
subprocess.run(["clang", "-O2", "-I.", str(src / "bench.c"), *flags, "-o", str(exe)], check=True)
if win:
    for dll in Path(runtime).rglob("*.dll"):
        shutil.copy2(dll, work)
lexicon = next(path.name for path in Path(model).glob("lexicon*.txt") if "us" in path.name)
with (root / "results.csv").open("w", encoding="utf-8") as output:
    print("threads,input,load_s,load_mb,peak_mb,ttfa_s,generation_s,audio_s,callbacks,version", file=output, flush=True)
    for threads in [4, 2]:
        for mode in ["short", "split", "unsplit"]:
            row = subprocess.check_output([exe, str(threads), mode, lexicon], cwd=model, text=True)
            print(row, end="", flush=True)
            print(row, file=output, end="", flush=True)
