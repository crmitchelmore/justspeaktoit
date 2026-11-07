#!/usr/bin/env python3
"""Prepare pinned AdvanceCOMP in a private folder; no global installation."""
import argparse
import importlib.util
import json
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tarfile
import tempfile
import zipfile

HERE = Path(__file__).resolve().parent
sys.dont_write_bytecode = True
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))
import zip_optimization  # noqa: E402

# Reuse the existing pinned GitHub build-tool downloader, also used for 7-Zip.
spec = importlib.util.spec_from_file_location("runtime_pin", HERE / "pin-swift-runtime.py")
PIN = importlib.util.module_from_spec(spec)
spec.loader.exec_module(PIN)


def prepare(downloads, output):
    lock = json.loads((HERE / "archive-optimizer.json").read_text(encoding="utf-8"))
    if lock["version"] != zip_optimization.VERSION:
        raise ValueError("ZIP optimizer version and download pins differ")
    host = platform.system()
    if host == "Windows":
        if platform.machine().lower() not in ("amd64", "x86_64"):
            raise ValueError("The pinned Windows optimizer requires an x64 build host")
        pin, name = lock["windows-x64"], "advzip.exe"
    elif host in ("Darwin", "Linux"):
        pin, name = lock["source"], "advzip"
    else:
        raise ValueError("Unsupported ZIP optimizer build host: " + host)
    archive = PIN.download(pin, downloads)
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".prepare-advzip-", dir=output) as directory:
        work = Path(directory)
        staged = work / name
        if host == "Windows":
            with zipfile.ZipFile(archive) as source:
                staged.write_bytes(source.read(name))
        else:
            with tarfile.open(archive, "r:gz") as source:
                source.extractall(work, filter="data")
            root = work / ("advancecomp-" + lock["version"])
            subprocess.run(["./configure"], cwd=root, check=True, timeout=120)
            subprocess.run(["make", "-j4", "advzip"], cwd=root, check=True, timeout=300)
            shutil.copy2(root / name, staged)
        version = subprocess.run([str(staged), "--version"], check=True, capture_output=True,
                                 text=True, encoding="utf-8", timeout=15).stdout.strip()
        if not version.startswith("advancecomp v" + lock["version"] + " "):
            raise ValueError("Prepared optimizer has an unexpected version: " + version)
        receipt = {"version": lock["version"], "download": pin, "host": host,
                   "toolSHA256": zip_optimization.digest(staged)}
        staged.replace(output / name)
        record = work / "receipt.json"
        record.write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        record.replace(output / "archive-optimizer.json")
    return output / name


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--downloads", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    print(prepare(args.downloads.resolve(), args.output.resolve()))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        raise SystemExit("ZIP optimizer preparation: " + str(error))
