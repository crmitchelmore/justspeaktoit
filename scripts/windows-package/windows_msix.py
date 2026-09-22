"""Dependency-free helpers for the unsigned Windows x64 developer MSIX package.

The layout builder, the package verifier and the lifecycle test support share
this module. It never runs Windows tooling: MakeAppx, SignTool and the
deployment APIs run only from the PowerShell scripts on Windows. The runtime
payload is the verified self-contained bundle, reused through the bundle
builder's own policy, path and PE checks rather than a second dependency list.
"""
import base64
import hashlib
import importlib.util
import io
import json
import pathlib
import platform
import re
import string
import struct
import sys
import urllib.parse
import xml.etree.ElementTree as ET
import zipfile
import zlib
from xml.sax.saxutils import escape

HERE = pathlib.Path(__file__).resolve().parent
REPOSITORY = HERE.parent.parent
IDENTITY_PATH = HERE / "package-identity.json"
TEMPLATE_PATH = HERE / "AppxManifest.xml.in"
PACKAGE_MANIFEST = "package-manifest.json"
APPX_MANIFEST = "AppxManifest.xml"
sys.dont_write_bytecode = True


def _load_bundle_builder():
    # The bundle builder's file name has hyphens, so load it by path.
    spec = importlib.util.spec_from_file_location(
        "windows_bundle_builder", HERE.parent / "windows-bundle" / "build-windows-bundle.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


BUNDLE = _load_bundle_builder()
windows_pe = BUNDLE.windows_pe


class PackageError(Exception):
    """A package input violates the packaging policy; nothing is written."""


def sha256(data):
    return hashlib.sha256(data).hexdigest()


# --- identity rules -----------------------------------------------------------------
# Patterns are the Windows SDK 10.0.26100 AppxManifestTypes.xsd simple types
# named beside them. XSD patterns match the whole value, hence fullmatch.
_VERSION_PART = r"(0|[1-9][0-9]{0,3}|[1-5][0-9]{4}|6[0-4][0-9]{3}|65[0-4][0-9]{2}|655[0-2][0-9]|6553[0-5])"
VERSION_PATTERN = re.compile(_VERSION_PART + r"(\." + _VERSION_PART + r"){3}")  # ST_VersionQuad
_RDN = (r"(CN|L|O|OU|E|C|S|STREET|T|G|I|SN|DC|SERIALNUMBER|Description|PostalCode|POBox|Phone|X21Address|"
        r"dnQualifier|(OID\.(0|[1-9][0-9]*)(\.(0|[1-9][0-9]*))+))=(([^,+=\"<>#;])+|\".*\")")
PUBLISHER_PATTERN = re.compile(_RDN + r"(, " + _RDN + r")*")  # ST_Publisher_2010_v2
PACKAGE_NAME_PATTERN = re.compile(r"[-.A-Za-z0-9]{3,50}")  # ST_PackageName
APPLICATION_ID_PATTERN = re.compile(r"([A-Za-z][A-Za-z0-9]*)(\.[A-Za-z][A-Za-z0-9]*)*")  # ST_AsciiWindowsId
EXECUTABLE_PATTERN = re.compile(r"[^\\/]+\.[Ee][Xx][Ee]")  # ST_ExecutableNoPath, no directories
FILE_NAME_FORBIDDEN = re.compile(r"[<>\":%|?*\x00-\x1f]")  # ST_FileNameCharSet
PUBLISHER_ID_ALPHABET = "0123456789abcdefghjkmnpqrstvwxyz"
RESERVED_PACKAGE_FILES = {"appxmanifest.xml", "appxblockmap.xml", "[content_types].xml", "appxsignature.p7x"}
RESERVED_PACKAGE_DIRECTORIES = ("appxmetadata/", "microsoft.system.package.metadata/")


def _text(value, what, limit):
    # ST_NonEmptyString: no surrounding whitespace; manifests also refuse controls.
    if (not isinstance(value, str) or not value or value != value.strip() or len(value) > limit
            or re.search(r"[\x00-\x1f]", value)):
        raise PackageError("%s must be 1-%d characters without surrounding spaces or controls: %r" % (what, limit, value))
    return value


def validate_version(version):
    if not isinstance(version, str) or not VERSION_PATTERN.fullmatch(version):
        raise PackageError("package version must be four dot-separated integers 0-65535 without leading zeros: %r"
                           % (version,))
    return version


def version_tuple(version):
    return tuple(int(part) for part in validate_version(version).split("."))


def validate_publisher(publisher):
    _text(publisher, "publisher", 8192)
    if not PUBLISHER_PATTERN.fullmatch(publisher):
        raise PackageError("publisher is not an X.500 distinguished name the manifest schema accepts: " + publisher)
    return publisher


def validate_name(name):
    if (not isinstance(name, str) or not PACKAGE_NAME_PATTERN.fullmatch(name) or name.endswith(".")
            or name.split(".")[0].lower() in BUNDLE.RESERVED_NAMES):
        raise PackageError("package name must be 3-50 ASCII letters, digits, dots or hyphens: %r" % (name,))
    return name


def publisher_id(publisher):
    """Windows' 13-character publisher ID for a package family name.

    Base32 (Crockford alphabet, lower case) of the first 64 bits of the
    SHA-256 of the UTF-16LE publisher, padded with one zero bit.
    """
    value = int.from_bytes(hashlib.sha256(publisher.encode("utf-16-le")).digest()[:8], "big") << 1
    return "".join(PUBLISHER_ID_ALPHABET[(value >> (60 - 5 * index)) & 31] for index in range(13))


def package_identity(identity, version, publisher):
    name = identity["identity"]["name"]
    family = name + "_" + publisher_id(publisher)
    architecture = identity["identity"]["processorArchitecture"]
    return {"name": name, "publisher": publisher, "publisherId": publisher_id(publisher), "version": version,
            "architecture": architecture, "packageFamilyName": family,
            "packageFullName": "%s_%s_%s__%s" % (name, version, architecture, publisher_id(publisher)),
            "applicationId": identity["application"]["id"],
            "appUserModelId": family + "!" + identity["application"]["id"],
            "executionAlias": identity["application"]["executionAlias"],
            "displayName": identity["presentation"]["displayName"]}


def load_identity(path=IDENTITY_PATH):
    data = json.loads(pathlib.Path(path).read_text(encoding="utf-8"))
    if data.get("schemaVersion") != 1 or data.get("channel") != "developer" or data.get("releaseTrain") is not None:
        raise PackageError("package-identity.json must describe the developer channel outside the release trains")
    validate_name(data["identity"]["name"])
    validate_publisher(data["identity"]["developerPublisher"])
    if data["identity"]["processorArchitecture"] != "x64":
        raise PackageError("this package slice is x64 only")
    presentation = data["presentation"]
    for key in ("displayName", "publisherDisplayName"):
        # Windows refuses '|' in these names when it creates the firewall profile.
        if "|" in _text(presentation[key], key, 256):
            raise PackageError(key + " must not contain '|'")
    if "|" in _text(presentation["description"], "description", 2048):
        raise PackageError("description must not contain '|'")
    _text(presentation["language"], "language", 64)
    application = data["application"]
    if not APPLICATION_ID_PATTERN.fullmatch(application["id"]) or len(application["id"]) > 64:
        raise PackageError("application id is not a valid ST_AsciiWindowsId")
    for key in ("executable", "executionAlias"):
        if not EXECUTABLE_PATTERN.fullmatch(application[key]):
            raise PackageError(key + " must be an .exe file name without a directory")
    family = data["targetDeviceFamily"]
    if family["name"] != "Windows.Desktop" or version_tuple(family["minVersion"]) > version_tuple(family["maxVersionTested"]):
        raise PackageError("target device family must be Windows.Desktop with minVersion <= maxVersionTested")
    # uap10 activation attributes and desktop6 virtualisation need Windows 10 2004.
    if version_tuple(family["minVersion"]) < (10, 0, 19041, 0):
        raise PackageError("minVersion must be at least 10.0.19041.0")
    if data["capabilities"] != {"restricted": ["runFullTrust", "unvirtualizedResources"], "device": ["microphone"]}:
        raise PackageError("capabilities changed; update the manifest template and its review notes together")
    if data["fileSystem"]["writeVirtualization"] != "disabled":
        raise PackageError("file-system write virtualisation must stay disabled so uninstall retains user data")
    images = data["assets"]["images"]
    if not images or any(not path.startswith("Assets/") or not isinstance(size, int) or size < 16
                         for path, size in images.items()):
        raise PackageError("assets must be square PNG sizes under Assets/")
    return data


# --- PNG assets ------------------------------------------------------------------------
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


def _png_chunks(data):
    if data[:8] != PNG_SIGNATURE:
        raise PackageError("not a PNG image")
    position = 8
    while position + 12 <= len(data):
        length, kind = struct.unpack(">I4s", data[position:position + 8])
        end = position + 12 + length
        if end > len(data):
            break
        body = data[position + 8:end - 4]
        if zlib.crc32(kind + body) & 0xffffffff != struct.unpack(">I", data[end - 4:end])[0]:
            raise PackageError("PNG chunk checksum mismatch in " + kind.decode("latin-1"))
        yield kind, body
        if kind == b"IEND":
            return
        position = end
    raise PackageError("truncated PNG image")


def decode_png(data):
    """Decode 8-bit RGB/RGBA non-interlaced PNG, the canonical icon exports, to RGBA."""
    header, idat = None, []
    for kind, body in _png_chunks(data):
        if kind == b"IHDR":
            header = struct.unpack(">IIBBBBB", body)
        elif kind == b"IDAT":
            idat.append(body)
    if header is None or not idat:
        raise PackageError("PNG image lacks IHDR or IDAT")
    width, height, depth, colour, compression, method, interlace = header
    if depth != 8 or colour not in (2, 6) or compression or method or interlace or not width or not height:
        raise PackageError("unsupported PNG format: depth %d colour type %d interlace %d" % (depth, colour, interlace))
    channels = 4 if colour == 6 else 3
    stride = width * channels
    raw = zlib.decompress(b"".join(idat))
    if len(raw) != height * (stride + 1):
        raise PackageError("PNG image data has the wrong length")
    pixels = bytearray(width * height * 4)
    previous = bytearray(stride)
    for y in range(height):
        start = y * (stride + 1)
        kind = raw[start]
        row = bytearray(raw[start + 1:start + 1 + stride])
        if kind == 1:
            for i in range(channels, stride):
                row[i] = (row[i] + row[i - channels]) & 255
        elif kind == 2:
            for i in range(stride):
                row[i] = (row[i] + previous[i]) & 255
        elif kind == 3:
            for i in range(stride):
                left = row[i - channels] if i >= channels else 0
                row[i] = (row[i] + ((left + previous[i]) >> 1)) & 255
        elif kind == 4:
            for i in range(stride):
                a = row[i - channels] if i >= channels else 0
                b = previous[i]
                c = previous[i - channels] if i >= channels else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                row[i] = (row[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        elif kind != 0:
            raise PackageError("invalid PNG filter type %d" % kind)
        if channels == 4:
            pixels[y * width * 4:(y + 1) * width * 4] = row
        else:
            for x in range(width):
                offset = (y * width + x) * 4
                pixels[offset:offset + 3] = row[x * 3:x * 3 + 3]
                pixels[offset + 3] = 255
        previous = row
    return width, height, bytes(pixels)


def _png_chunk(kind, body):
    return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xffffffff)


def encode_png(width, height, rgba):
    if len(rgba) != width * height * 4:
        raise PackageError("RGBA buffer does not match the image size")
    stride = width * 4
    raw = b"".join(b"\x00" + rgba[y * stride:(y + 1) * stride] for y in range(height))
    return (PNG_SIGNATURE + _png_chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
            + _png_chunk(b"sRGB", b"\x00") + _png_chunk(b"IDAT", zlib.compress(raw, 9)) + _png_chunk(b"IEND", b""))


def _area_weights(source, target):
    # Integer overlap of each source pixel with each target pixel, measured in
    # 1/target of a source pixel. Every target's weights sum to ``source``.
    weights = []
    for index in range(target):
        start, end = index * source, (index + 1) * source
        row = []
        for pixel in range(start // target, min(source, -(-end // target))):
            overlap = min(end, (pixel + 1) * target) - max(start, pixel * target)
            if overlap > 0:
                row.append((pixel, overlap))
        weights.append(row)
    return weights


def _rounded_quotient(numerator, denominator):
    return (2 * numerator + denominator) // (2 * denominator)


def resample_rgba(width, height, rgba, target_width, target_height):
    """Exact area average of premultiplied RGBA using integers only.

    Transparent pixels contribute no colour, so rounded corners do not darken,
    and every host produces identical pixels regardless of its zlib or libm.
    """
    columns, rows = _area_weights(width, target_width), _area_weights(height, target_height)
    total = width * height
    output = bytearray(target_width * target_height * 4)
    for ty, row_weights in enumerate(rows):
        for tx, column_weights in enumerate(columns):
            alpha = red = green = blue = 0
            for sy, wy in row_weights:
                base = sy * width
                for sx, wx in column_weights:
                    offset = (base + sx) * 4
                    weight = wx * wy * rgba[offset + 3]
                    alpha += weight
                    red += weight * rgba[offset]
                    green += weight * rgba[offset + 1]
                    blue += weight * rgba[offset + 2]
            out = (ty * target_width + tx) * 4
            if alpha:
                output[out] = _rounded_quotient(red, alpha)
                output[out + 1] = _rounded_quotient(green, alpha)
                output[out + 2] = _rounded_quotient(blue, alpha)
            output[out + 3] = _rounded_quotient(alpha, total)
    return bytes(output)


def render_assets(identity, source_root=REPOSITORY):
    """Derive the package logos from the canonical app icon export."""
    source = identity["assets"]["source"]
    data = (pathlib.Path(source_root) / source).read_bytes()
    width, height, rgba = decode_png(data)
    if width != height:
        raise PackageError("the icon source must be square")
    assets = {}
    for path, size in sorted(identity["assets"]["images"].items()):
        if size > width:
            raise PackageError("the icon source is smaller than " + path)
        assets[path] = encode_png(size, size, resample_rgba(width, height, rgba, size, size))
    record = {"source": source, "sourceSHA256": sha256(data), "sourceSize": [width, height],
              "method": "exact integer area average of premultiplied RGBA; unfiltered 8-bit RGBA PNG output",
              "images": dict(sorted(identity["assets"]["images"].items()))}
    return assets, record


# --- manifest ----------------------------------------------------------------------------
NAMESPACES = {
    "f": "http://schemas.microsoft.com/appx/manifest/foundation/windows10",
    "uap": "http://schemas.microsoft.com/appx/manifest/uap/windows10",
    "uap3": "http://schemas.microsoft.com/appx/manifest/uap/windows10/3",
    "uap10": "http://schemas.microsoft.com/appx/manifest/uap/windows10/10",
    "desktop": "http://schemas.microsoft.com/appx/manifest/desktop/windows10",
    "desktop6": "http://schemas.microsoft.com/appx/manifest/desktop/windows10/6",
    "rescap": "http://schemas.microsoft.com/appx/manifest/foundation/windows10/restrictedcapabilities",
}


def render_manifest(identity, version, publisher, template_path=TEMPLATE_PATH):
    presentation, application = identity["presentation"], identity["application"]
    family = identity["targetDeviceFamily"]
    values = {
        "name": identity["identity"]["name"], "publisher": validate_publisher(publisher),
        "version": validate_version(version), "architecture": identity["identity"]["processorArchitecture"],
        "displayName": presentation["displayName"], "publisherDisplayName": presentation["publisherDisplayName"],
        "description": presentation["description"], "language": presentation["language"],
        "fileSystemWriteVirtualization": identity["fileSystem"]["writeVirtualization"],
        "deviceFamily": family["name"], "minVersion": family["minVersion"],
        "maxVersionTested": family["maxVersionTested"], "applicationId": application["id"],
        "executable": application["executable"], "executionAlias": application["executionAlias"],
    }
    escaped = {key: escape(value, {'"': "&quot;"}) for key, value in values.items()}
    data = string.Template(pathlib.Path(template_path).read_text(encoding="utf-8")).substitute(escaped).encode("utf-8")
    check_manifest(data, identity, version, publisher)
    return data


def check_manifest(data, identity, version, publisher):
    """Check the rendered manifest states exactly the reviewed identity and policy."""
    try:
        root = ET.fromstring(data)
    except ET.ParseError as error:
        raise PackageError("manifest is not well-formed XML: %s" % error)
    ns = NAMESPACES
    if root.tag != "{%s}Package" % ns["f"]:
        raise PackageError("manifest root must be the foundation Package element")
    if "desktop6" in (root.get("IgnorableNamespaces") or "").split():
        raise PackageError("desktop6 must not be ignorable: an OS that cannot honour it must refuse the package")
    found = root.find("f:Identity", ns)
    expected = {"Name": identity["identity"]["name"], "Publisher": publisher, "Version": version,
                "ProcessorArchitecture": identity["identity"]["processorArchitecture"]}
    if found is None or {key: found.get(key) for key in expected} != expected:
        raise PackageError("manifest identity differs from the requested identity")
    if root.findtext("f:Properties/desktop6:FileSystemWriteVirtualization", namespaces=ns) != "disabled":
        raise PackageError("manifest must disable file-system write virtualisation")
    applications = root.findall("f:Applications/f:Application", ns)
    application = identity["application"]
    if (len(applications) != 1 or applications[0].get("Id") != application["id"]
            or applications[0].get("Executable") != application["executable"]
            or applications[0].get("{%s}TrustLevel" % ns["uap10"]) != "mediumIL"
            or applications[0].get("{%s}RuntimeBehavior" % ns["uap10"]) != "packagedClassicApp"):
        raise PackageError("manifest must declare exactly the full-trust packaged desktop application")
    aliases = [element.get("Alias") for element in applications[0].iter("{%s}ExecutionAlias" % ns["desktop"])]
    if aliases != [application["executionAlias"]]:
        raise PackageError("manifest must declare exactly the reviewed execution alias")
    capabilities = root.find("f:Capabilities", ns)
    names = [(element.tag, element.get("Name")) for element in capabilities]
    restricted = [name for tag, name in names if tag == "{%s}Capability" % ns["rescap"]]
    device = [name for tag, name in names if tag == "{%s}DeviceCapability" % ns["f"]]
    if (restricted != identity["capabilities"]["restricted"] or device != identity["capabilities"]["device"]
            or len(names) != len(restricted) + len(device)):
        raise PackageError("manifest capabilities differ from package-identity.json")
    # The schema sequence puts every Capability before any DeviceCapability.
    if names[:len(restricted)] != [("{%s}Capability" % ns["rescap"], name) for name in restricted]:
        raise PackageError("restricted capabilities must precede device capabilities")
    logos = {root.findtext("f:Properties/f:Logo", namespaces=ns)}
    visual = applications[0].find("uap:VisualElements", ns)
    logos |= {visual.get("Square150x150Logo"), visual.get("Square44x44Logo")}
    declared = {path.replace("/", "\\") for path in identity["assets"]["images"]}
    if logos != declared:
        raise PackageError("manifest logos differ from the generated assets")
    return root


# --- runtime bundle input ---------------------------------------------------------------------
def pe_subsystem(data):
    offset = struct.unpack_from("<I", data, 0x3c)[0]
    optional = offset + 24
    if struct.unpack_from("<H", data, optional)[0] != 0x20b:
        raise PackageError("expected a PE32+ executable")
    value = struct.unpack_from("<H", data, optional + 68)[0]
    return {2: "windows", 3: "console"}.get(value, "subsystem-%d" % value)


def _reserved_package_path(path):
    lower = path.lower()
    return lower in RESERVED_PACKAGE_FILES or lower.startswith(RESERVED_PACKAGE_DIRECTORIES)


def verify_bundle(bundle_dir, expected_commit=None):
    """Authenticate the runtime bundle exactly as the bundle job recorded it.

    Returns the archive's entries by path. Refuses a changed archive, a
    different source commit, extra or tampered files, a test-enabled build, a
    runtime policy other than the repository's, and reserved package paths.
    """
    bundle_dir = pathlib.Path(bundle_dir)
    try:
        evidence = json.loads((bundle_dir / "bundle-evidence.json").read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise PackageError("cannot read bundle-evidence.json: %s" % error)
    archive_record = evidence.get("zip") or {}
    name = archive_record.get("name")
    if not isinstance(name, str) or pathlib.PurePosixPath(name).name != name or not name.endswith(".zip") or "\\" in name:
        raise PackageError("bundle evidence names an unexpected archive")
    archive = bundle_dir / name
    if not archive.is_file() or archive.is_symlink():
        raise PackageError("bundle archive is missing: " + name)
    data = archive.read_bytes()
    if len(data) != archive_record.get("bytes") or sha256(data) != archive_record.get("sha256"):
        raise PackageError("bundle archive does not match bundle-evidence.json")
    commit = (evidence.get("application") or {}).get("sourceCommit")
    if expected_commit is not None and commit != expected_commit:
        raise PackageError("bundle source commit %s does not match %s" % (commit, expected_commit))
    try:
        with zipfile.ZipFile(io.BytesIO(data)) as bundle:
            infos = bundle.infolist()
            if len({info.filename.lower() for info in infos}) != len(infos):
                raise PackageError("bundle archive repeats a path")
            for info in infos:
                if info.is_dir():
                    raise PackageError("bundle archive contains a directory entry: " + info.filename)
                BUNDLE.check_bundle_path(info.filename)
            entries = {info.filename: bundle.read(info) for info in infos}
    except (zipfile.BadZipFile, BUNDLE.BundleError) as error:
        raise PackageError("bundle archive is invalid: %s" % error)
    manifest_bytes = entries.get("bundle-manifest.json")
    if manifest_bytes is None or sha256(manifest_bytes) != (evidence.get("manifest") or {}).get("sha256"):
        raise PackageError("bundle-manifest.json does not match bundle-evidence.json")
    manifest = json.loads(manifest_bytes)
    application = manifest.get("application") or {}
    executable = entries.get(BUNDLE.APPLICATION)
    if (application.get("configuration") != "release" or application.get("appBuiltForTesting") is not False
            or application.get("sourceCommit") != commit or executable is None
            or application.get("executableSHA256") != sha256(executable)
            or (evidence.get("application") or {}).get("executableSHA256") != sha256(executable)):
        raise PackageError("bundle does not hold the recorded optimised production executable")
    policy = BUNDLE.Policy.load()
    if manifest.get("policy") != policy.data:
        raise PackageError("bundle was assembled under a different runtime policy than this repository's")
    rows = {}
    for row in manifest.get("files") or []:
        path = row.get("path")
        if path in rows or path not in entries:
            raise PackageError("bundle manifest lists a missing or repeated file: %r" % (path,))
        if len(entries[path]) != row.get("bytes") or sha256(entries[path]) != row.get("sha256"):
            raise PackageError("bundle file does not match its manifest hash: " + path)
        rows[path] = row
    extra = sorted(set(entries) - set(rows) - {"bundle-manifest.json"})
    if extra:
        raise PackageError("bundle archive holds files its manifest does not list: " + ", ".join(extra))
    try:
        BUNDLE.check_bundle_layout(sorted(entries), policy)
    except BUNDLE.BundleError as error:
        raise PackageError(str(error))
    reserved = [path for path in entries if _reserved_package_path(path)]
    if reserved:
        raise PackageError("bundle uses reserved package paths: " + ", ".join(sorted(reserved)))
    image = windows_pe.PEImage(executable, BUNDLE.APPLICATION)
    if not image.is_x64 or image.is_dll:
        raise PackageError("SpeakWindows.exe is not a Windows x64 executable")
    for module in image.imports() + image.delay_imports():
        if policy.classify(module) == BUNDLE.TEST_MODULE:
            raise PackageError("SpeakWindows.exe imports the test library " + module)
    for module in (manifest.get("dependencies") or {}).get("bundled", {}).values():
        if module.get("name") not in entries:
            raise PackageError("bundled runtime module is missing: %r" % (module.get("name"),))
    return {"evidence": evidence, "manifest": manifest, "manifestSHA256": sha256(manifest_bytes),
            "entries": entries, "rows": rows, "commit": commit,
            "archive": {"name": name, "sha256": archive_record["sha256"], "bytes": archive_record["bytes"]},
            "executableSHA256": sha256(executable), "subsystem": pe_subsystem(executable)}


# --- layout ------------------------------------------------------------------------------------
def _check_package_path(path):
    BUNDLE.check_bundle_path(path)
    if FILE_NAME_FORBIDDEN.search(path):
        raise PackageError("package file names cannot contain <>\":%|?* or controls: " + path)
    return path


def build_layout(bundle_dir, output_dir, version, publisher=None, expected_commit=None,
                 identity=None, source_root=REPOSITORY):
    """Write ``output_dir/layout`` (the exact package payload) and its evidence."""
    identity = identity or load_identity()
    publisher = validate_publisher(publisher or identity["identity"]["developerPublisher"])
    version = validate_version(version)
    bundle_dir, output_dir = pathlib.Path(bundle_dir).resolve(), pathlib.Path(output_dir).resolve()
    if bundle_dir == output_dir or bundle_dir in output_dir.parents or output_dir in bundle_dir.parents:
        raise PackageError("keep the bundle input and the package output separate")
    if output_dir.exists() and (not output_dir.is_dir() or any(output_dir.iterdir())):
        raise PackageError("package output must be a new or empty directory")
    bundle = verify_bundle(bundle_dir, expected_commit)
    executable = identity["application"]["executable"]
    if executable not in bundle["entries"]:
        raise PackageError("the bundle does not contain " + executable)
    assets, asset_record = render_assets(identity, source_root)
    files = {path: (data, "bundle") for path, data in bundle["entries"].items()}
    for path, data in assets.items():
        if path.lower() in {existing.lower() for existing in files}:
            raise PackageError("generated asset collides with a bundle file: " + path)
        files[path] = (data, "generated-asset")
    files[APPX_MANIFEST] = (render_manifest(identity, version, publisher), "generated-manifest")
    for path in files:
        _check_package_path(path)
    try:
        BUNDLE.check_bundle_layout(sorted(files) + [PACKAGE_MANIFEST], BUNDLE.Policy.load())
    except BUNDLE.BundleError as error:
        raise PackageError(str(error))
    rows = []
    for path in sorted(files):
        data, origin = files[path]
        row = {"path": path, "bytes": len(data), "sha256": sha256(data), "origin": origin}
        if origin == "bundle" and path in bundle["rows"]:
            row["bundleSource"] = bundle["rows"][path]["source"]
        rows.append(row)
    identity_record = package_identity(identity, version, publisher)
    package_manifest = {
        "schemaVersion": 1,
        "package": dict(identity_record, kind="unsigned Windows x64 developer MSIX payload", signed=False,
                        channel=identity["channel"], releaseTrain=None),
        "fileSystem": identity["fileSystem"],
        "capabilities": identity["capabilities"],
        "targetDeviceFamily": identity["targetDeviceFamily"],
        "executable": {"path": executable, "sha256": bundle["executableSHA256"], "subsystem": bundle["subsystem"]},
        "bundle": {"archive": bundle["archive"], "manifestSHA256": bundle["manifestSHA256"],
                   "sourceCommit": bundle["commit"], "runtimeModules": sorted(
                       module["name"] for module in bundle["manifest"]["dependencies"]["bundled"].values())},
        "assets": asset_record,
        "files": rows,
    }
    manifest_bytes = (json.dumps(package_manifest, indent=2, sort_keys=True) + "\n").encode("utf-8")
    layout = output_dir / "layout"
    layout.mkdir(parents=True)
    for path, (data, _) in sorted(files.items()):
        destination = layout / path
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(data)
    (layout / PACKAGE_MANIFEST).write_bytes(manifest_bytes)
    evidence = {
        "schemaVersion": 1,
        "package": identity_record,
        "layout": {"directory": "layout", "files": len(rows) + 1, "packageManifestSHA256": sha256(manifest_bytes),
                   "appxManifestSHA256": sha256(files[APPX_MANIFEST][0])},
        "bundle": package_manifest["bundle"],
        "executableSubsystem": bundle["subsystem"],
        "host": {"system": platform.system(), "machine": platform.machine(), "python": platform.python_version(),
                 "zlib": zlib.ZLIB_RUNTIME_VERSION},
        "status": "Layout only. MakeAppx packing and Windows installation are separate receipts.",
    }
    (output_dir / "package-layout-evidence.json").write_text(json.dumps(evidence, indent=2, sort_keys=True) + "\n",
                                                             encoding="utf-8")
    return evidence


def verify_layout(layout_dir):
    """Return the layout's package manifest after checking every file against it."""
    layout_dir = pathlib.Path(layout_dir)
    manifest_bytes = (layout_dir / PACKAGE_MANIFEST).read_bytes()
    package_manifest = json.loads(manifest_bytes)
    expected = {row["path"]: row for row in package_manifest["files"]}
    actual = {}
    for path in sorted(layout_dir.rglob("*")):
        if path.is_symlink():
            raise PackageError("layout contains a link: " + str(path))
        if path.is_file():
            actual[path.relative_to(layout_dir).as_posix()] = path
    if set(actual) != set(expected) | {PACKAGE_MANIFEST}:
        missing = sorted(set(expected) - set(actual))
        extra = sorted(set(actual) - set(expected) - {PACKAGE_MANIFEST})
        raise PackageError("layout differs from its package manifest; missing %s, unexpected %s" % (missing, extra))
    hashes = {PACKAGE_MANIFEST: sha256(manifest_bytes)}
    for path, row in expected.items():
        data = actual[path].read_bytes()
        if len(data) != row["bytes"] or sha256(data) != row["sha256"]:
            raise PackageError("layout file changed after it was built: " + path)
        hashes[path] = row["sha256"]
    return package_manifest, hashes


# --- MSIX verification ------------------------------------------------------------------------
BLOCKMAP_NAMESPACE = "http://schemas.microsoft.com/appx/2010/blockmap"
SHA256_METHOD = "http://www.w3.org/2001/04/xmlenc#sha256"
BLOCK_SIZE = 65536
BLOCKMAP_PART = "AppxBlockMap.xml"
CONTENT_TYPES_PART = "[Content_Types].xml"
SIGNATURE_PART = "AppxSignature.p7x"


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


def block_hashes(data):
    return [base64.b64encode(hashlib.sha256(data[offset:offset + BLOCK_SIZE]).digest()).decode("ascii")
            for offset in range(0, len(data), BLOCK_SIZE)]


def verify_package(package_path, layout_dir, signed, unsigned_reference=None):
    """Check an .msix holds exactly the layout's bytes under a valid SHA-256 block map.

    MakeAppx is the authoritative packer; this independent reader proves its
    output still equals the verified layout, and that signing changed nothing
    except adding the signature part.
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
            payload = set(parts) - {BLOCKMAP_PART, CONTENT_TYPES_PART, SIGNATURE_PART}
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
            if set(listed) != payload:
                raise PackageError("block map does not list exactly the payload files")
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
        raise PackageError("package is unreadable: %s" % error)
    if unsigned_reference is not None:
        with zipfile.ZipFile(unsigned_reference) as reference:
            if reference.read(BLOCKMAP_PART) != blockmap_bytes:
                raise PackageError("signing changed the block map of the unsigned package")
    data = package_path.read_bytes()
    return {"name": package_path.name, "sha256": sha256(data), "bytes": len(data), "signed": bool(signed),
            "payloadFiles": len(payload), "blockMapSHA256": sha256(blockmap_bytes),
            "packageManifestSHA256": layout_hashes[PACKAGE_MANIFEST], "identity": package_manifest["package"]}
