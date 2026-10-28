#!/usr/bin/env python3
"""Stage a native Linux desktop layout; never install into the running system."""
import argparse
import pathlib
import shutil
import struct
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
APP_ID = "com.justspeaktoit.JustSpeakToIt"
sys.path.insert(0, str(ROOT / "scripts" / "local-llm-runtime"))
import local_llm_package


def resource_bundles(directory):
    bundles = []
    for bundle in sorted(pathlib.Path(directory).glob("*.resources")):
        target = bundle.name.removesuffix(".resources")
        if target.endswith("Tests") or target == "SpeakTestSupport" or target.endswith("_SpeakTestSupport"):
            continue
        if bundle.is_symlink() or not bundle.is_dir():
            raise ValueError(f"the production resource bundle must be a regular directory: {bundle.name}")
        for entry in bundle.rglob("*"):
            if entry.is_symlink() or not (entry.is_file() or entry.is_dir()):
                raise ValueError(f"unsupported resource entry: {bundle.name}/{entry.relative_to(bundle)}")
        bundles.append(bundle)
    return bundles


def stage(binary, output, prefix="/usr/local", local_llm_runtime=None, *, cli=None):
    binary, output = pathlib.Path(binary), pathlib.Path(output)
    if not binary.is_file() or binary.is_symlink():
        raise ValueError("the built SpeakLinux executable must be a regular file")
    if cli is not None:
        cli = pathlib.Path(cli)
        if not cli.is_file() or cli.is_symlink():
            raise ValueError("the built speak executable must be a regular file")
    if not prefix.startswith("/") or any(value in prefix for value in ("\n", "\r", "\0")):
        raise ValueError("the install prefix must be an absolute Linux path without controls")
    if any(value in prefix for value in ("%", "=")):
        raise ValueError("the install prefix cannot contain percent or equal signs in a desktop executable path")
    theme = binary.parent / "SpeakApp_SpeakLinux.resources/hicolor"
    core = binary.parent / "SpeakApp_SpeakCore.resources"
    bundles = resource_bundles(binary.parent)
    if core not in bundles or theme.parent not in bundles or not theme.is_dir():
        raise ValueError("the built executable's Linux icon and core resource bundles must be present")
    runtime = None
    if local_llm_runtime is not None:
        with binary.open("rb") as stream:
            header = stream.read(64)
        if len(header) != 64 or header[:7] != b"\x7fELF\x02\x01\x01":
            raise ValueError("native LLM staging requires an ELF64 production application")
        kind, machine = struct.unpack_from("<HH", header, 16)
        architecture = {62: "x86_64", 183: "arm64"}.get(machine)
        if kind not in (2, 3) or architecture is None:
            raise ValueError("native LLM staging requires a supported native application architecture")
        runtime = local_llm_package.read_directory(local_llm_runtime, "linux", architecture)
    if output.exists():
        raise ValueError("the staging output must be a new directory")
    output.mkdir(parents=True)
    destination = output / "bin"
    destination.mkdir()
    shutil.copy2(binary, destination / "justspeaktoit")
    (destination / "justspeaktoit").chmod(0o755)
    if cli is not None:
        shutil.copy2(cli, destination / "speak")
        (destination / "speak").chmod(0o755)
    for bundle in bundles:
        shutil.copytree(bundle, destination / bundle.name)
    if runtime is not None:
        runtime_directory = destination / local_llm_package.DIRECTORY
        runtime_directory.mkdir()
        for name, data in runtime["entries"].items():
            (runtime_directory / name).write_bytes(data)
            (runtime_directory / name).chmod(0o644)
    # Keep the host's standard hicolor index; the private runtime bundle owns
    # its minimal index, not the installed system theme.
    shutil.copytree(theme, output / "share/icons/hicolor", ignore=shutil.ignore_patterns("index.theme"))
    desktop = (ROOT / f"packaging/linux/{APP_ID}.desktop").read_text(encoding="utf-8")
    # Desktop Entry escaping: quoted Exec values need two levels of backslashes.
    executable = prefix.rstrip("/") + "/bin/justspeaktoit"
    quoted = executable.replace("\\", "\\\\\\\\").replace('"', '\\\\"').replace("`", "\\\\`").replace("$", "\\\\$")
    desktop = desktop.replace("Exec=justspeaktoit", f'Exec="{quoted}"')
    applications = output / "share/applications"
    applications.mkdir(parents=True)
    (applications / f"{APP_ID}.desktop").write_text(desktop, encoding="utf-8", newline="\n")
    metainfo = output / "share/metainfo"
    metainfo.mkdir(parents=True)
    shutil.copy2(ROOT / f"packaging/linux/{APP_ID}.metainfo.xml", metainfo)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=pathlib.Path)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--prefix", default="/usr/local", help="eventual install prefix; staging remains under --output")
    parser.add_argument("--local-llm-runtime", type=pathlib.Path,
                        help="pinned offline native cleanup build's LocalLLMRuntime directory; no acquisition")
    parser.add_argument("--cli", type=pathlib.Path, help="built speak executable to stage alongside the app")
    args = parser.parse_args()
    stage(args.binary, args.output, args.prefix, args.local_llm_runtime, cli=args.cli)


if __name__ == "__main__":
    main()
