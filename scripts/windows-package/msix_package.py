"""Independently verify a MakeAppx package: exactly the layout's bytes under
a valid SHA-256 block map, and a signature that changed nothing else."""
import base64
import hashlib
import pathlib
import urllib.parse
import xml.etree.ElementTree as ET
import zipfile

from msix_identity import PackageError, sha256
from msix_layout import APPX_MANIFEST, PACKAGE_MANIFEST, verify_layout

BLOCKMAP_NAMESPACE = "http://schemas.microsoft.com/appx/2010/blockmap"
SHA256_METHOD = "http://www.w3.org/2001/04/xmlenc#sha256"
BLOCK_SIZE = 65536
BLOCKMAP_PART = "AppxBlockMap.xml"
CONTENT_TYPES_PART = "[Content_Types].xml"
SIGNATURE_PART = "AppxSignature.p7x"
# SignTool catalogues the package's PE files here while signing. It is a
# signing artifact, never payload, and appears only beside a signature.
CODE_INTEGRITY_PART = "AppxMetadata/CodeIntegrity.cat"


def _package_parts(archive):
    parts = {}
    for info in archive.infolist():
        if info.filename.endswith("/"):
            raise PackageError("package contains a directory entry: " + info.filename)
        # OPC part names are percent-encoded; the block map uses real names.
        name = urllib.parse.unquote(info.filename)
        if name.lower() in {existing.lower() for existing in parts}:
            raise PackageError("package repeats a part: " + name)
        parts[name] = info
    return parts


def _blockmap_entries(blockmap_bytes, ignored):
    """Hash method and per-file size and block hashes, without signing artifacts."""
    root = ET.fromstring(blockmap_bytes)
    entries = {}
    for element in root.findall("{%s}File" % BLOCKMAP_NAMESPACE):
        name = (element.get("Name") or "").replace("\\", "/")
        if name in ignored:
            continue
        entries[name] = (element.get("Size"), tuple(block.get("Hash") for block in
                                                     element.findall("{%s}Block" % BLOCKMAP_NAMESPACE)))
    return root.get("HashMethod"), entries


def block_hashes(data):
    return [base64.b64encode(hashlib.sha256(data[offset:offset + BLOCK_SIZE]).digest()).decode("ascii")
            for offset in range(0, len(data), BLOCK_SIZE)]


def verify_package(package_path, layout_dir, signed, unsigned_reference=None):
    """Check an .msix holds exactly the layout's bytes under a valid SHA-256 block map.

    MakeAppx is the authoritative packer; this independent reader proves its
    output still equals the verified layout, and that signing changed nothing
    except adding the signature and its code integrity catalogue, which the
    signed block map may list with matching hashes.
    """
    package_manifest, layout_hashes = verify_layout(layout_dir)
    package_path = pathlib.Path(package_path)
    try:
        with zipfile.ZipFile(package_path) as archive:
            parts = _package_parts(archive)
            for required in (BLOCKMAP_PART, CONTENT_TYPES_PART, APPX_MANIFEST):
                if required not in parts:
                    raise PackageError("package lacks " + required)
            if (SIGNATURE_PART in parts) != bool(signed):
                raise PackageError("package is %s but %s was expected" % (
                    "signed" if SIGNATURE_PART in parts else "unsigned", "signed" if signed else "unsigned"))
            signing = {SIGNATURE_PART, CODE_INTEGRITY_PART} if signed else {SIGNATURE_PART}
            payload = set(parts) - {BLOCKMAP_PART, CONTENT_TYPES_PART} - signing
            if payload != set(layout_hashes):
                raise PackageError("package payload differs from the layout; missing %s, unexpected %s" % (
                    sorted(set(layout_hashes) - payload), sorted(payload - set(layout_hashes))))
            blockmap_bytes = archive.read(parts[BLOCKMAP_PART])
            root = ET.fromstring(blockmap_bytes)
            if root.tag != "{%s}BlockMap" % BLOCKMAP_NAMESPACE or root.get("HashMethod") != SHA256_METHOD:
                raise PackageError("block map must use SHA-256")
            listed = {}
            for element in root.findall("{%s}File" % BLOCKMAP_NAMESPACE):
                name = (element.get("Name") or "").replace("\\", "/")
                if name in listed:
                    raise PackageError("block map repeats " + name)
                listed[name] = element
            catalogue = {CODE_INTEGRITY_PART} & set(listed) & set(parts) if signed else set()
            if set(listed) - catalogue != payload:
                raise PackageError("block map does not list exactly the payload files")
            for name in sorted(catalogue):
                data = archive.read(parts[name])
                recorded = [block.get("Hash") for block in listed[name].findall("{%s}Block" % BLOCKMAP_NAMESPACE)]
                if int(listed[name].get("Size", "-1")) != len(data) or recorded != block_hashes(data):
                    raise PackageError("block map hashes do not match " + name)
            for name in sorted(payload):
                data = archive.read(parts[name])
                if sha256(data) != layout_hashes[name]:
                    raise PackageError("package file differs from the layout: " + name)
                element = listed[name]
                recorded = [block.get("Hash") for block in element.findall("{%s}Block" % BLOCKMAP_NAMESPACE)]
                if int(element.get("Size", "-1")) != len(data) or recorded != block_hashes(data):
                    raise PackageError("block map hashes do not match " + name)
            ET.fromstring(archive.read(parts[CONTENT_TYPES_PART]))
    except (zipfile.BadZipFile, ET.ParseError, KeyError, ValueError) as error:
        raise PackageError("package is unreadable: %s" % error) from error
    if unsigned_reference is not None:
        with zipfile.ZipFile(unsigned_reference) as reference:
            unsigned_bytes = reference.read(BLOCKMAP_PART)
        if unsigned_bytes != blockmap_bytes and (
                _blockmap_entries(unsigned_bytes, set()) != _blockmap_entries(blockmap_bytes, {CODE_INTEGRITY_PART})):
            raise PackageError("signing changed the block map of the unsigned package")
    data = package_path.read_bytes()
    return {"name": package_path.name, "sha256": sha256(data), "bytes": len(data), "signed": bool(signed),
            "payloadFiles": len(payload), "blockMapSHA256": sha256(blockmap_bytes),
            "packageManifestSHA256": layout_hashes[PACKAGE_MANIFEST], "identity": package_manifest["package"]}
