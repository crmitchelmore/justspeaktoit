"""Dependency-free helpers for the Windows MSIX packages (developer, beta and store channels, x64 or ARM64).

The layout builder, the package verifier and the lifecycle test support share
this module. It never runs Windows tooling: MakeAppx, SignTool and the
deployment APIs run only from the PowerShell scripts on Windows. The runtime
payload is the verified self-contained bundle, reused through the bundle
builder's own policy, path and PE checks rather than a second dependency list.
The package's processor architecture is the bundle's.
"""
import importlib.util
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
sys.dont_write_bytecode = True
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))


def _load_bundle_builder():
    # The bundle builder's file name has hyphens, so load it by path.
    spec = importlib.util.spec_from_file_location(
        "windows_bundle_builder", HERE.parent / "windows-bundle" / "build-windows-bundle.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


BUNDLE = _load_bundle_builder()
windows_pe = BUNDLE.windows_pe
windows_targets = BUNDLE.windows_targets

# Each phase is its own module; this one re-exports their surface for the
# layout, verification and installer scripts and their tests.
from msix_assets import (
    PNG_SIGNATURE,
    _area_weights,
    _rounded_quotient,
    decode_png,
    encode_png,
    render_assets,
    resample_rgba,
)
from msix_identity import (
    BETA_IDENTITY_PATH,
    CHANNEL_IDENTITIES,
    IDENTITY_PATH,
    IDENTITY_PATHS,
    REPOSITORY,
    STORE_IDENTITY_PATH,
    STORE_RESERVATION,
    PackageError,
    fixed_publisher,
    load_identity,
    package_identity,
    processor_architecture,
    publisher_id,
    sha256,
    validate_name,
    validate_publisher,
    validate_version,
    version_tuple,
)
from msix_layout import APPX_MANIFEST, PACKAGE_MANIFEST, build_layout, pe_subsystem, verify_bundle, verify_layout
from msix_manifest import NAMESPACES, TEMPLATE_PATH, check_manifest, render_manifest
from msix_package import (
    BLOCK_SIZE,
    BLOCKMAP_NAMESPACE,
    BLOCKMAP_PART,
    CODE_INTEGRITY_PART,
    CONTENT_TYPES_PART,
    SHA256_METHOD,
    SIGNATURE_PART,
    _blockmap_entries,
    block_hashes,
    verify_package,
)

__all__ = [
    "APPX_MANIFEST", "BETA_IDENTITY_PATH", "BLOCKMAP_NAMESPACE", "BLOCKMAP_PART", "BLOCK_SIZE", "BUNDLE",
    "CHANNEL_IDENTITIES", "CODE_INTEGRITY_PART", "CONTENT_TYPES_PART", "IDENTITY_PATH", "IDENTITY_PATHS",
    "NAMESPACES", "PACKAGE_MANIFEST", "PNG_SIGNATURE", "REPOSITORY", "SHA256_METHOD", "SIGNATURE_PART",
    "STORE_IDENTITY_PATH", "STORE_RESERVATION",
    "TEMPLATE_PATH", "PackageError", "_area_weights", "_blockmap_entries", "_rounded_quotient", "block_hashes",
    "build_layout", "check_manifest", "decode_png", "encode_png", "fixed_publisher", "load_identity", "package_identity", "pe_subsystem",
    "processor_architecture", "publisher_id", "render_assets", "render_manifest", "resample_rgba", "sha256",
    "validate_name", "validate_publisher", "validate_version", "verify_bundle", "verify_layout", "verify_package",
    "version_tuple", "windows_pe", "windows_targets",
]
