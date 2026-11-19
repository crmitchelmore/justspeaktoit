#!/usr/bin/env python3
"""Assemble the self-contained, unsigned Windows developer runtime bundle.

For x64, inputs are the Mac cross-build output (``build-windows-app.py``) and
the private cross-build cache (for the Swift 6.2.3 runtime DLLs and their
installer provenance). For ARM64 they are the native Windows ARM64 build
staged by ``stage-native-app.py`` and the runtime that ``pin-swift-runtime.py``
extracted from the pinned ARM64 installer, with its lock. Both use pinned
official downloads (Microsoft's Visual C++ runtime and licence texts). The
output is a deterministic ZIP holding production ``SpeakWindows.exe`` and
``speak.exe``, their SwiftPM resources, only the runtime DLLs reached from both roots' static
and delay-load import closure, licence notices and a manifest of hashes and
provenance. Every executable and DLL must be an image a native process of the
bundle's architecture loads. Compiler, SDK, header, import-library, symbol,
installer and test files are refused.
"""
import argparse
import json
import pathlib
import platform
import sys
import zlib

HERE = pathlib.Path(__file__).resolve().parent
sys.dont_write_bytecode = True
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))
import redistributables
import windows_pe
import windows_targets

# The phases live in bundle_policy, bundle_sources, bundle_notices and
# bundle_assembly. This entry point re-exports the builder's surface that the
# MSIX packager and the packaging tests load through this file.
from bundle_assembly import (
    assemble,
    cross_check_with_llvm,
    local_llm_library_path,
    local_llm_package,
    local_llm_source,
    parse_llvm_readobj_imports,
    verify_local_llm_payload,
)
from bundle_notices import SUPPORTED_WINDOWS, microsoft_notice_text, microsoft_runtime_name, notices_text, readme_text
from bundle_policy import (
    APPLICATION,
    CLI,
    EXECUTABLES,
    LOCAL_RUNTIME,
    MICROSOFT_RUNTIME,
    RESERVED_NAMES,
    SWIFT_RUNTIME,
    SYSTEM_MODULE,
    TEST_MODULE,
    UNKNOWN_MODULE,
    ZIP_TIMESTAMP,
    BundleError,
    Log,
    Policy,
    check_bundle_layout,
    check_bundle_path,
    digest_file,
    resolve_closure,
    sha256,
    static_modules,
    validate_executable,
    write_deterministic_zip,
)
from bundle_sources import (
    ALLOWED_DOWNLOAD_HOSTS,
    APPLICATION_HOSTS,
    LOCAL_RUNTIME_PINS,
    NETWORK_RETRY_DELAYS,
    download,
    download_with_retry,
    load_application,
    load_local_llm_runtime,
    load_local_runtime,
    load_microsoft_runtime,
    load_swift_runtime,
    read_swift_module,
)

__all__ = [
    "ALLOWED_DOWNLOAD_HOSTS", "APPLICATION", "APPLICATION_HOSTS", "CLI", "EXECUTABLES", "LOCAL_RUNTIME",
    "LOCAL_RUNTIME_PINS", "MICROSOFT_RUNTIME", "NETWORK_RETRY_DELAYS", "RESERVED_NAMES", "SUPPORTED_WINDOWS",
    "SWIFT_RUNTIME", "SYSTEM_MODULE", "TEST_MODULE", "UNKNOWN_MODULE", "ZIP_TIMESTAMP", "BundleError", "Log",
    "Policy", "assemble", "check_bundle_layout", "check_bundle_path", "check_output_separation",
    "cross_check_with_llvm", "digest_file", "download", "download_with_retry", "load_application",
    "load_local_llm_runtime", "load_local_runtime", "load_microsoft_runtime", "load_swift_runtime",
    "local_llm_library_path", "local_llm_package", "local_llm_source", "main", "microsoft_notice_text",
    "microsoft_runtime_name", "notices_text", "parse_llvm_readobj_imports", "read_swift_module", "readme_text",
    "redistributables", "resolve_closure", "sha256", "static_modules", "swift_runtime_inputs",
    "validate_executable", "verify_local_llm_payload", "windows_pe", "windows_targets", "write_deterministic_zip",
]


def check_output_separation(app, cache, output):
    if (app == output or cache == output or cache in output.parents or output in cache.parents
            or app in output.parents or output in app.parents):
        raise BundleError("Keep the app output, private cache and bundle output separate")


def swift_runtime_inputs(args, architecture):
    """``(runtime directory, lock path)``: the cross-build cache for x64 by default, explicit paths otherwise."""
    committed = HERE / windows_targets.target(architecture)["swiftRuntimeLock"]
    if args.swift_runtime is not None:
        return args.swift_runtime.resolve(), (args.swift_runtime_lock or committed).resolve()
    if architecture != "x64" or args.cache is None:
        raise BundleError("pass --swift-runtime and --swift-runtime-lock (pin-swift-runtime.py --runtime-output) "
                          "for %s, or --cache for the x64 cross-build" % architecture)
    return args.cache.resolve() / "swift-windows", (args.swift_runtime_lock or committed).resolve()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--architecture", default="x64", choices=sorted(windows_targets.TARGETS))
    parser.add_argument("--app", required=True, type=pathlib.Path,
                        help="build-windows-app.py (x64) or stage-native-app.py (ARM64) output directory")
    parser.add_argument("--cache", type=pathlib.Path, help="private x64 cross-build cache (read only)")
    parser.add_argument("--swift-runtime", type=pathlib.Path,
                        help="Swift runtime extracted by pin-swift-runtime.py --runtime-output")
    parser.add_argument("--swift-runtime-lock", type=pathlib.Path,
                        help="lock for that runtime (default: the architecture's committed lock)")
    parser.add_argument("--downloads", required=True, type=pathlib.Path, help="writable directory for pinned downloads")
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--source-root", type=pathlib.Path, default=HERE.parent.parent)
    parser.add_argument("--llvm-readobj", type=pathlib.Path, help="cross-check import tables with llvm-readobj")
    parser.add_argument("--local-runtime", type=pathlib.Path,
                        help="whisper.cpp runtime build (build-whisper-runtime.py output) to bundle for on-device transcription")
    parser.add_argument("--local-llm-runtime", type=pathlib.Path,
                        help="pinned offline native cleanup build's LocalLLMRuntime directory; no acquisition")
    args = parser.parse_args()
    architecture = args.architecture
    runtime_directory, lock_path = swift_runtime_inputs(args, architecture)
    app, output = args.app.resolve(), args.output.resolve()
    check_output_separation(app, args.cache.resolve() if args.cache else runtime_directory, output)
    output.mkdir(parents=True, exist_ok=True)
    log = Log(output / "bundle-build.log")
    local_runtime = load_local_runtime(args.local_runtime.resolve(), architecture=architecture) if args.local_runtime else None
    local_llm = load_local_llm_runtime(args.local_llm_runtime, architecture) if args.local_llm_runtime else None
    runtime_names = [module["name"] for module in local_runtime["modules"].values()] if local_runtime else []
    policy = Policy.load(local_runtime=runtime_names + (["llama.dll"] if local_llm else []))
    lock = json.loads((HERE / "dependencies.json").read_text(encoding="utf-8"))
    application = load_application(app, policy, architecture)
    swift = load_swift_runtime(runtime_directory, lock_path, architecture)
    committed = HERE / windows_targets.target(architecture)["swiftRuntimeLock"]
    swift["lockOrigin"] = ("committed " + committed.name if committed.is_file() and lock_path == committed.resolve()
                           else "regenerated in this build from the pinned installer; no committed lock was compared")
    log("Swift runtime lock: " + swift["lockOrigin"])
    downloads = args.downloads.resolve()
    microsoft = load_microsoft_runtime(download(lock["microsoftRuntime"], downloads), lock["microsoftRuntime"], log,
                                       architecture)
    licenses = []
    for entry in lock["licenses"]:
        path = download(entry, downloads)
        licenses.append(dict(entry, data=path.read_bytes()))
    sys.path.insert(0, str(HERE.parent / "migration"))
    from migration_dependency import license_entry
    try:
        licenses.append(license_entry(args.source_root))
    except (ValueError, OSError, KeyError) as error:
        raise BundleError("Cannot verify the native migration dependency: " + str(error)) from error
    app_license_path = args.source_root / "LICENSE"
    app_license = app_license_path.read_bytes()
    if b"MIT License" not in app_license:
        raise BundleError("unexpected application licence at " + str(app_license_path))
    cross_check = args.llvm_readobj.resolve() if args.llvm_readobj else None
    if cross_check is not None and not cross_check.is_file():
        raise BundleError("llvm-readobj not found at " + str(cross_check))
    entries, manifest = assemble(application, swift, microsoft, licenses, app_license, policy,
                                 lock["microsoftRuntime"], cross_check, log, local_runtime, architecture, local_llm)
    manifest_bytes = (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode()
    entries["bundle-manifest.json"] = manifest_bytes
    commit = manifest["application"]["sourceCommit"]
    name = "justspeaktoit-windows-%s-developer-%s.zip" % (architecture, commit[:7] if commit else "local")
    archive = output / name
    names = write_deterministic_zip(archive, entries)
    archive_digest = digest_file(archive)
    (output / "bundle-manifest.json").write_bytes(manifest_bytes)
    evidence = {
        "schemaVersion": 1,
        "architecture": architecture,
        "zip": {"name": name, "sha256": archive_digest, "bytes": archive.stat().st_size, "entries": len(names)},
        "manifest": {"name": "bundle-manifest.json", "sha256": sha256(manifest_bytes)},
        "application": {"sourceCommit": commit, "executableSHA256": manifest["application"]["executableSHA256"],
                        "executables": manifest["application"]["executables"]},
        "bundledModules": [entry["name"] for entry in manifest["dependencies"]["bundled"].values()],
        "host": {"system": platform.system(), "machine": platform.machine(), "python": platform.python_version(),
                 "zlib": zlib.ZLIB_RUNTIME_VERSION},
        "llvmReadobjCrossCheck": cross_check is not None,
        "runtimeStatus": "Windows execution with an isolated PATH remains required",
    }
    (output / "bundle-evidence.json").write_text(json.dumps(evidence, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    log("Bundled %d files into %s (%s)" % (len(names), name, archive_digest))
    log("Runtime modules: " + ", ".join(evidence["bundledModules"]))


if __name__ == "__main__":
    try:
        main()
    except (BundleError, redistributables.ExtractionError, windows_pe.PEFormatError, ValueError) as error:
        raise SystemExit("windows bundle: " + str(error)) from error
