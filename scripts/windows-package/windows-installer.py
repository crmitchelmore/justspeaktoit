#!/usr/bin/env python3
"""Windows beta installer helper: package version, App Installer file and bundle verification.

  version       --build 202610301641                 -> 2026.1030.1641.0
  appinstaller  --bundle-uri URI --publisher P --version V --output F [--self-uri URI] [--rehearsal]
  verify-bundle --bundle B --publisher P --version V --package ARCH=FILE [...] (--signed|--unsigned) [--evidence F]

Published App Installer files must point at the website URI and an immutable
GitHub release asset; ``--rehearsal`` permits file URIs for CI install tests.
"""
import argparse
import json
import pathlib
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import windows_installer  # noqa: E402
import windows_msix  # noqa: E402


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    version = commands.add_parser("version")
    version.add_argument("--build", required=True)
    appinstaller = commands.add_parser("appinstaller")
    appinstaller.add_argument("--self-uri", default=windows_installer.APPINSTALLER_URI)
    appinstaller.add_argument("--bundle-uri", required=True)
    appinstaller.add_argument("--publisher", required=True)
    appinstaller.add_argument("--version", required=True)
    appinstaller.add_argument("--output", required=True, type=pathlib.Path)
    appinstaller.add_argument("--rehearsal", action="store_true")
    verify = commands.add_parser("verify-bundle")
    verify.add_argument("--bundle", required=True, type=pathlib.Path)
    verify.add_argument("--publisher", required=True)
    verify.add_argument("--version", required=True)
    verify.add_argument("--package", action="append", required=True, metavar="ARCH=FILE",
                        help="an inner package MakeAppx bundled; repeat per architecture")
    state = verify.add_mutually_exclusive_group(required=True)
    state.add_argument("--signed", action="store_true")
    state.add_argument("--unsigned", action="store_true")
    verify.add_argument("--evidence", type=pathlib.Path)
    args = parser.parse_args(argv)
    name = windows_msix.load_identity(windows_msix.BETA_IDENTITY_PATH)["identity"]["name"]
    if args.command == "version":
        print(windows_installer.package_version(args.build))
    elif args.command == "appinstaller":
        data = windows_installer.render_appinstaller(args.self_uri, args.bundle_uri, name, args.publisher,
                                                     args.version, allow_any_uri=args.rehearsal)
        args.output.write_bytes(data)
        print(data.decode("utf-8"), end="")
    else:
        packages, originals = {}, {}
        for value in args.package:
            architecture, _, path = value.partition("=")
            path = pathlib.Path(path)
            if architecture in packages or not path.is_file():
                parser.error("--package needs distinct ARCH=FILE values naming existing files: " + value)
            originals[architecture] = path.read_bytes()
            packages[architecture] = (path.name, windows_msix.sha256(originals[architecture]))
        result = windows_installer.verify_bundle(args.bundle, name, args.publisher, args.version, packages,
                                                 args.signed, originals)
        text = json.dumps(result, indent=2, sort_keys=True) + "\n"
        if args.evidence:
            args.evidence.write_text(text, encoding="utf-8")
        print(text, end="")


if __name__ == "__main__":
    try:
        main()
    except windows_msix.PackageError as error:
        raise SystemExit("windows installer: " + str(error)) from error
