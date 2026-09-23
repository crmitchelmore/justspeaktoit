#!/usr/bin/env python3
"""Regenerate the reviewed DLL lock from the SHA-256-pinned official installer.

Uses the private, pinned 7-Zip tool as a data extractor, never runs the installer.
Normal x64 bundle builds need only the committed lock, not another installer copy.

The installer's two cabinets are located from its ``.wixburn`` header, so the
same code reads the x64 and ARM64 Swift installers. ``--runtime-output`` keeps
the extracted runtime DLLs for a bundle build; ``--compare`` then fails unless
the regenerated lock equals a committed one.
"""
import argparse
import hashlib
import json
import mmap
from pathlib import Path
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

HERE = Path(__file__).resolve().parent
sys.dont_write_bytecode = True
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))
import redistributables  # noqa: E402
import windows_targets  # noqa: E402

DOWNLOAD_HOSTS = {"download.swift.org", "github.com"}
RUNTIME_PACKAGE = {"rtl.msi", "rtl.cab"}
check_size = windows_targets.installer_size_matches


class PinError(ValueError):
    """An input differs from its pin or the installer layout changed."""


def digest(path, algorithm="sha256"):
    result = hashlib.new(algorithm)
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            result.update(chunk)
    return result.hexdigest()


def installer_pin(architecture):
    """``(Swift version, installer pin)`` for the architecture's runtime."""
    swift_version, pin, _ = windows_targets.swift_runtime_installer(architecture)
    return swift_version, pin


def download(pin, directory):
    url = urllib.parse.urlsplit(pin["url"])
    if url.scheme != "https" or url.hostname not in DOWNLOAD_HOSTS:
        raise PinError("unexpected download source: " + pin["url"])
    if Path(pin["name"]).name != pin["name"]:
        raise PinError("download name must be a basename: " + pin["name"])
    directory.mkdir(parents=True, exist_ok=True)
    destination = directory / pin["name"]
    if destination.exists():
        if not check_size(pin, destination.stat().st_size) or digest(destination) != pin["sha256"]:
            raise PinError("cached download differs from its pin: " + pin["name"])
        return destination
    limit = pin.get("bytes", pin.get("maximumBytes"))
    partial = destination.with_name(pin["name"] + ".partial")
    print("Downloading pinned file: " + pin["name"], flush=True)
    with urllib.request.urlopen(pin["url"], timeout=300) as response, partial.open("wb") as output:
        count = 0
        while chunk := response.read(1024 * 1024):
            count += len(chunk)
            if count > limit:
                raise PinError("download exceeded its pinned size: " + pin["name"])
            output.write(chunk)
    if not check_size(pin, partial.stat().st_size) or digest(partial) != pin["sha256"]:
        partial.unlink()
        raise PinError("download differs from its pin: " + pin["name"])
    partial.replace(destination)
    return destination


def pinned_seven(downloads, cross=windows_targets.CROSS_PINS):
    """The macOS 7-Zip console pinned for the cross build, extracted beside its download."""
    lock = json.loads(Path(cross).read_text(encoding="utf-8"))
    pin = next(item for item in lock["downloads"] if item["name"].endswith("-mac.tar.xz"))
    archive = download(pin, downloads)
    target = downloads / "sevenzip"
    if not (target / "7zz").exists():
        target.mkdir(exist_ok=True)
        subprocess.run(["tar", "-xf", str(archive), "-C", str(target)], check=True)
    return target / "7zz"


def carve_containers(installer, workspace):
    """Copy the bundle's UX and attached cabinets out of the installer."""
    with installer.open("rb") as stream, mmap.mmap(stream.fileno(), 0, access=mmap.ACCESS_READ) as source:
        containers = redistributables.burn_containers(source)
        if len(containers) != 2:
            raise PinError("expected the bootstrap and payload cabinets in " + installer.name)
        for name, (offset, size) in zip(["bootstrap", "payloads"], containers):
            with (workspace / (name + ".cab")).open("xb") as output:
                for start in range(offset, offset + size, 1024 * 1024):
                    output.write(source[start:min(start + 1024 * 1024, offset + size)])
    return containers


def generate(installer, seven, temporary_parent, architecture="x64", runtime_output=None):
    swift_version, pin = installer_pin(architecture)
    size = installer.stat().st_size
    if not check_size(pin, size) or digest(installer) != pin["sha256"]:
        raise PinError("Swift installer differs from the committed SHA-256 pin")
    with tempfile.TemporaryDirectory(prefix="swift-runtime-pin-", dir=temporary_parent) as temporary:
        workspace = Path(temporary)
        carve_containers(installer, workspace)

        def extract(source, output, names=()):
            subprocess.run([str(seven), "x", str(source), "-o" + str(output), "-y", "-bsp0", "-bso0",
                            *names], check=True)
        extract(workspace / "bootstrap.cab", workspace / "bootstrap", ["0"])
        manifest = workspace / "bootstrap/0"
        payloads = [item for item in ET.parse(manifest).iter()
                    if item.tag.endswith("Payload") and item.get("FilePath") in RUNTIME_PACKAGE]
        if sorted(item.get("FilePath") for item in payloads) != sorted(RUNTIME_PACKAGE):
            raise PinError("Pinned installer lacks the runtime package")
        extract(workspace / "payloads.cab", workspace / "payloads", [item.get("SourcePath") for item in payloads])
        (workspace / "packages").mkdir()
        receipts = {}
        for item in payloads:
            path = workspace / "payloads" / item.get("SourcePath")
            expected = {"bytes": int(item.get("FileSize")), "sha512": item.get("Hash").lower()}
            if path.stat().st_size != expected["bytes"] or digest(path, "sha512") != expected["sha512"]:
                raise PinError("Embedded runtime payload failed authentication")
            path.rename(workspace / "packages" / item.get("FilePath"))
            receipts[item.get("FilePath")] = expected
        # Reconstruct MSI names with the already qualified shared decoder.
        runtime = Path(runtime_output) if runtime_output else workspace / "runtime"
        subprocess.run([sys.executable, "-B", str(HERE.parent / "windows-cross/extract-msi.py"), "rtl",
                        "--workspace", str(workspace), "--seven", str(seven), "--output", str(runtime)],
                       check=True)
        files = []
        for row in json.loads((workspace / "rtl-layout.json").read_text(encoding="utf-8")):
            if row["path"].lower().endswith(".dll"):
                files.append(dict(row, sha256=digest(runtime / row["path"])))
        installer_record = {key: pin[key] for key in ("name", "url", "sha256")} | {"bytes": size}
        return {"schemaVersion": 1, "architecture": architecture, "swiftVersion": swift_version,
                "installer": installer_record, "bootstrapManifestSHA256": digest(manifest), "payloads": receipts,
                "files": sorted(files, key=lambda item: item["path"])}


def render(document):
    return json.dumps(document, indent=2, sort_keys=True) + "\n"


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--architecture", default="x64", choices=["x64", "arm64"])
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--installer", type=Path, help="an already downloaded installer")
    source.add_argument("--downloads", type=Path, help="download the pinned installer (and 7-Zip) here")
    parser.add_argument("--seven", type=Path, help="7-Zip console (default with --downloads: the pinned macOS 7-Zip)")
    parser.add_argument("--temporary-parent", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path, help="lock file to write")
    parser.add_argument("--runtime-output", type=Path, help="new directory that keeps the extracted runtime")
    parser.add_argument("--compare", type=Path, help="committed lock the regenerated lock must equal")
    args = parser.parse_args(argv)
    if args.runtime_output is not None and args.runtime_output.exists() and any(args.runtime_output.iterdir()):
        raise PinError("--runtime-output must be a new or empty directory")
    installer = args.installer
    if installer is None:
        installer = download(installer_pin(args.architecture)[1], args.downloads)
    seven = args.seven
    if seven is None:
        if args.downloads is None:
            raise PinError("--seven is required with --installer")
        seven = pinned_seven(args.downloads)
    document = generate(installer, seven, args.temporary_parent, args.architecture, args.runtime_output)
    args.output.write_text(render(document), encoding="utf-8")
    print("Authenticated and pinned", len(document["files"]), args.architecture, "runtime DLLs from",
          document["installer"]["name"], "(%d bytes)" % document["installer"]["bytes"])
    if args.compare is not None:
        committed = json.loads(args.compare.read_text(encoding="utf-8"))
        if committed != document:
            raise PinError("the regenerated lock differs from " + str(args.compare))
        print("The regenerated lock equals", args.compare)


if __name__ == "__main__":
    try:
        main()
    except (PinError, redistributables.ExtractionError, subprocess.CalledProcessError, OSError, ValueError) as error:
        raise SystemExit("pin swift runtime: " + str(error))
