#!/usr/bin/env python3
"""Build the payload layout of an unsigned Windows MSIX package (developer or beta channel).

The input is the self-contained runtime bundle directory (bundle-evidence.json
and its ZIP); the package's processor architecture (x64 or arm64) is the
bundle's. Its archive, manifest, per-file hashes, source commit, runtime
policy, image architectures and production executable are authenticated first; the layout then
holds those bytes unchanged plus a generated AppxManifest.xml, logos derived
from the canonical app icon and package-manifest.json. MakeAppx packs the
layout on Windows. The version must be supplied explicitly. The beta channel
(the public App Installer package) has no default publisher: pass the signing
certificate's exact subject.
"""
import argparse
import json
import pathlib
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import windows_msix  # noqa: E402


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", required=True, type=pathlib.Path, help="runtime bundle directory")
    parser.add_argument("--output", required=True, type=pathlib.Path, help="new or empty output directory")
    parser.add_argument("--version", required=True, help="explicit four-part package version, e.g. 0.0.42.1")
    parser.add_argument("--publisher", help="certificate subject for an externally signed build "
                        "(defaults to the unsigned developer publisher)")
    parser.add_argument("--channel", choices=sorted(windows_msix.IDENTITY_PATHS), default="developer",
                        help="package identity: the developer package or the public beta installer package")
    parser.add_argument("--expected-commit", help="refuse a bundle built from another source commit")
    parser.add_argument("--source-root", type=pathlib.Path, default=windows_msix.REPOSITORY)
    args = parser.parse_args()
    identity = windows_msix.load_identity(windows_msix.IDENTITY_PATHS[args.channel])
    evidence = windows_msix.build_layout(args.bundle, args.output, args.version, publisher=args.publisher,
                                         expected_commit=args.expected_commit, identity=identity,
                                         source_root=args.source_root)
    print(json.dumps({"package": evidence["package"], "layout": evidence["layout"]}, indent=2, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except (windows_msix.PackageError, windows_msix.BUNDLE.BundleError, windows_msix.windows_pe.PEFormatError) as error:
        raise SystemExit("windows package: " + str(error))
