#!/usr/bin/env python3
"""Stage a native Linux desktop layout; never install into the running system."""
import argparse
import pathlib
import shutil

ROOT = pathlib.Path(__file__).resolve().parent.parent
APP_ID = "com.justspeaktoit.JustSpeakToIt"


def resource_bundles(directory):
    bundles = []
    for bundle in sorted(pathlib.Path(directory).glob("*.resources")):
        if bundle.name.removesuffix(".resources").endswith("Tests"):
            continue
        if bundle.is_symlink() or not bundle.is_dir():
            raise ValueError(f"the production resource bundle must be a regular directory: {bundle.name}")
        for entry in bundle.rglob("*"):
            if entry.is_symlink() or not (entry.is_file() or entry.is_dir()):
                raise ValueError(f"unsupported resource entry: {bundle.name}/{entry.relative_to(bundle)}")
        bundles.append(bundle)
    return bundles


def stage(binary, output, prefix="/usr/local"):
    binary, output = pathlib.Path(binary), pathlib.Path(output)
    if not binary.is_file() or binary.is_symlink():
        raise ValueError("the built SpeakLinux executable must be a regular file")
    if not prefix.startswith("/") or any(value in prefix for value in ("\n", "\r", "\0")):
        raise ValueError("the install prefix must be an absolute Linux path without controls")
    if any(value in prefix for value in ("%", "=")):
        raise ValueError("the install prefix cannot contain percent or equal signs in a desktop executable path")
    theme = binary.parent / "SpeakApp_SpeakLinux.resources/hicolor"
    core = binary.parent / "SpeakApp_SpeakCore.resources"
    bundles = resource_bundles(binary.parent)
    if core not in bundles or theme.parent not in bundles or not theme.is_dir():
        raise ValueError("the built executable's Linux icon and core resource bundles must be present")
    if output.exists():
        raise ValueError("the staging output must be a new directory")
    output.mkdir(parents=True)
    destination = output / "bin"
    destination.mkdir()
    shutil.copy2(binary, destination / "justspeaktoit")
    (destination / "justspeaktoit").chmod(0o755)
    for bundle in bundles:
        shutil.copytree(bundle, destination / bundle.name)
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
    args = parser.parse_args()
    stage(args.binary, args.output, args.prefix)


if __name__ == "__main__":
    main()
