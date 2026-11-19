"""Dependency-free helpers for the public Windows beta installer.

The installer is one signed ``.msixbundle`` holding the x64 and ARM64 beta
packages, plus an App Installer file (``.appinstaller``) that Windows' App
Installer opens directly from the website. App Installer picks the package for
the PC's architecture, records the file's own URI and checks it again for
updates. Since December 2023 the ``ms-appinstaller:`` web protocol is disabled
by default, so the website serves the file as a download rather than a
protocol link.

Nothing here signs, packs or installs: MakeAppx, SignTool and the deployment
APIs run only from the PowerShell scripts on Windows. This module derives the
package version from a release manifest, renders and checks the App Installer
file, and independently reads a bundle to prove what it holds.
"""
import hashlib
import io
import pathlib
import re
import sys
import urllib.parse
import xml.etree.ElementTree as ET
import zipfile
from xml.sax.saxutils import escape

sys.dont_write_bytecode = True
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import windows_msix  # noqa: E402

PackageError = windows_msix.PackageError
# The 2018 schema has OnLaunch prompts and the background update task and is
# understood by every Windows release the package supports (10.0.19041+).
APPINSTALLER_NAMESPACE = "http://schemas.microsoft.com/appx/appinstaller/2018"
BUNDLE_NAMESPACE = "http://schemas.microsoft.com/appx/2013/bundle"
BUNDLE_MANIFEST = "AppxMetadata/AppxBundleManifest.xml"
BUILD_PATTERN = re.compile(r"[0-9]{12}")
HOURS_BETWEEN_UPDATE_CHECKS = 12
SITE = "https://justspeaktoit.com"
APPINSTALLER_URI = SITE + "/alpha/windows/JustSpeakToIt.appinstaller"
RELEASE_DOWNLOAD = re.compile(r"https://github\.com/crmitchelmore/justspeaktoit/releases/download/"
                              r"(alpha-build|stable-candidate)-[1-9][0-9]*/[A-Za-z0-9._-]+\.msixbundle")


def package_version(build):
    """The four-part package version for a release manifest's 12-digit build.

    Builds are allocated strictly increasing across Alpha and Stable candidates.
    Splitting the digits into three groups of four keeps that order exactly
    (each group is at most 9999, under the 65535 limit) and the fourth part is
    zero, so every later build is a newer package version.
    """
    if not isinstance(build, str) or not BUILD_PATTERN.fullmatch(build):
        raise PackageError("release build must be 12 digits: %r" % (build,))
    version = ".".join(str(int(build[index:index + 4])) for index in (0, 4, 8)) + ".0"
    return windows_msix.validate_version(version)


def bundle_file_name(version):
    return "JustSpeakToIt-windows_%s.msixbundle" % windows_msix.validate_version(version)


def _check_https(uri, what):
    parsed = urllib.parse.urlsplit(uri if isinstance(uri, str) else "")
    if parsed.scheme != "https" or not parsed.netloc or parsed.query or parsed.fragment or any(
            character in uri for character in "<>\"' "):
        raise PackageError("%s must be a plain https URL: %r" % (what, uri))
    return uri


def render_appinstaller(self_uri, bundle_uri, name, publisher, version, allow_any_uri=False):
    """The App Installer file for ``bundle_uri``; ``allow_any_uri`` is for local rehearsals only."""
    windows_msix.validate_name(name)
    windows_msix.validate_publisher(publisher)
    windows_msix.validate_version(version)
    if not allow_any_uri:
        _check_https(self_uri, "App Installer URI")
        _check_https(bundle_uri, "bundle URI")
        if self_uri != APPINSTALLER_URI or not RELEASE_DOWNLOAD.fullmatch(bundle_uri):
            raise PackageError("published App Installer files must use the website URI and an immutable release asset")
    values = {key: escape(value, {'"': "&quot;"}) for key, value in {
        "self": self_uri, "bundle": bundle_uri, "name": name, "publisher": publisher, "version": version}.items()}
    text = ('<?xml version="1.0" encoding="utf-8"?>\n'
            '<AppInstaller xmlns="%s" Version="%s" Uri="%s">\n'
            '  <MainBundle Name="%s" Publisher="%s" Version="%s" Uri="%s"/>\n'
            '  <UpdateSettings>\n'
            '    <OnLaunch HoursBetweenUpdateChecks="%d" ShowPrompt="true" UpdateBlocksActivation="false"/>\n'
            '    <AutomaticBackgroundTask/>\n'
            '  </UpdateSettings>\n'
            '</AppInstaller>\n') % (APPINSTALLER_NAMESPACE, values["version"], values["self"], values["name"],
                                    values["publisher"], values["version"], values["bundle"],
                                    HOURS_BETWEEN_UPDATE_CHECKS)
    data = text.encode("utf-8")
    check_appinstaller(data, name, publisher, version)
    return data


def check_appinstaller(data, name, publisher, version):
    """Return the main bundle URI after checking the file states exactly this bundle and update policy."""
    try:
        root = ET.fromstring(data)
    except ET.ParseError as error:
        raise PackageError("App Installer file is not well-formed XML: %s" % error) from error
    ns = {"a": APPINSTALLER_NAMESPACE}
    if root.tag != "{%s}AppInstaller" % APPINSTALLER_NAMESPACE or root.get("Version") != version or not root.get("Uri"):
        raise PackageError("App Installer root must state its own URI and the bundle version")
    children = [child.tag.rsplit("}", 1)[-1] for child in root]
    if children != ["MainBundle", "UpdateSettings"]:
        raise PackageError("App Installer file must hold exactly MainBundle then UpdateSettings")
    bundle = root.find("a:MainBundle", ns)
    if {key: bundle.get(key) for key in ("Name", "Publisher", "Version")} != {
            "Name": name, "Publisher": publisher, "Version": version} or not bundle.get("Uri"):
        raise PackageError("App Installer MainBundle differs from the signed bundle identity")
    settings = root.find("a:UpdateSettings", ns)
    if [child.tag.rsplit("}", 1)[-1] for child in settings] != ["OnLaunch", "AutomaticBackgroundTask"]:
        raise PackageError("App Installer must check on launch and in the background")
    launch = settings.find("a:OnLaunch", ns)
    if launch.attrib != {"HoursBetweenUpdateChecks": str(HOURS_BETWEEN_UPDATE_CHECKS), "ShowPrompt": "true",
                         "UpdateBlocksActivation": "false"}:
        raise PackageError("App Installer OnLaunch policy changed")
    return bundle.get("Uri")


def _bundle_manifest(archive):
    names = {urllib.parse.unquote(info.filename): info for info in archive.infolist()}
    if BUNDLE_MANIFEST not in names:
        raise PackageError("bundle lacks " + BUNDLE_MANIFEST)
    return names, ET.fromstring(archive.read(names[BUNDLE_MANIFEST]))


def _same_entries(data, original, file_name, signed):
    """Check a bundled package is ``original`` apart from what SignTool adds when it signs the bundle.

    Signing a bundle also signs each inner package: that adds AppxSignature.p7x
    and, for packages with executables, AppxMetadata/CodeIntegrity.cat, lists the
    catalogue in the block map and registers both content types. Every other
    entry, and every payload hash in the block map, must be unchanged.
    """
    signing = {windows_msix.SIGNATURE_PART, windows_msix.CODE_INTEGRITY_PART} if signed else set()
    rewritten = {windows_msix.BLOCKMAP_PART, windows_msix.CONTENT_TYPES_PART} if signed else set()
    with zipfile.ZipFile(io.BytesIO(data)) as bundled, zipfile.ZipFile(io.BytesIO(original)) as source:
        bundled_names, source_names = set(bundled.namelist()), set(source.namelist())
        added, missing = bundled_names - source_names, source_names - bundled_names
        if missing or not added <= signing or (signed and windows_msix.SIGNATURE_PART not in added):
            raise PackageError("bundled %s entries differ: added %r, missing %r" % (
                file_name, sorted(added)[:5], sorted(missing)[:5]))
        changed = sorted(entry for entry in source_names - rewritten if bundled.read(entry) != source.read(entry))
        if changed:
            raise PackageError("bundled %s changes %d entries, for example %r" % (file_name, len(changed), changed[:5]))
        if signed and windows_msix._blockmap_entries(source.read(windows_msix.BLOCKMAP_PART), set()) != \
                windows_msix._blockmap_entries(bundled.read(windows_msix.BLOCKMAP_PART), {windows_msix.CODE_INTEGRITY_PART}):
            raise PackageError("signing changed the block map of " + file_name)


def verify_bundle(bundle_path, name, publisher, version, packages, signed, originals=None):
    """Check a bundle holds exactly ``packages`` ({architecture: (file name, sha256)}) under one identity.

    Every inner package must carry the bundle's name, publisher and version and
    the declared architecture; their bytes must be the packages MakeAppx was
    given. Signing a bundle adds only its AppxSignature.p7x. If MakeAppx stored a
    package as a different ZIP container, ``originals`` ({architecture: bytes})
    lets the check accept it only when every entry, including the block map
    that the bundle signature covers, is byte-for-byte the original's.
    """
    bundle_path = pathlib.Path(bundle_path)
    try:
        with zipfile.ZipFile(bundle_path) as archive:
            names, root = _bundle_manifest(archive)
            if (windows_msix.SIGNATURE_PART in names) != bool(signed):
                raise PackageError("bundle is %s but %s was expected" % (
                    "signed" if windows_msix.SIGNATURE_PART in names else "unsigned",
                    "signed" if signed else "unsigned"))
            ns = {"b": BUNDLE_NAMESPACE}
            identity = root.find("b:Identity", ns)
            expected = {"Name": name, "Publisher": publisher, "Version": version}
            if identity is None or {key: identity.get(key) for key in expected} != expected:
                raise PackageError("bundle identity differs from the requested identity")
            listed = {}
            for element in root.findall("b:Packages/b:Package", ns):
                if element.get("Type") != "application" or element.get("Version") != version:
                    raise PackageError("bundle may hold only application packages of its own version")
                architecture = element.get("Architecture")
                if architecture in listed:
                    raise PackageError("bundle repeats the %s architecture" % architecture)
                listed[architecture] = element.get("FileName")
            if listed != {architecture: file_name for architecture, (file_name, _) in packages.items()}:
                raise PackageError("bundle packages differ: %r" % (listed,))
            payload = set(names) - {BUNDLE_MANIFEST, windows_msix.BLOCKMAP_PART, windows_msix.CONTENT_TYPES_PART,
                                    windows_msix.SIGNATURE_PART}
            if payload != set(listed.values()):
                raise PackageError("bundle files differ from its manifest: %r" % (sorted(payload),))
            inner = {}
            for architecture, (file_name, digest) in sorted(packages.items()):
                data = archive.read(names[file_name])
                repacked = windows_msix.sha256(data) != digest
                if repacked:
                    original = (originals or {}).get(architecture)
                    if original is None or windows_msix.sha256(original) != digest:
                        raise PackageError("bundle holds different bytes for " + file_name)
                    _same_entries(data, original, file_name, signed)
                with zipfile.ZipFile(io.BytesIO(data)) as package:
                    manifest = ET.fromstring(package.read(windows_msix.APPX_MANIFEST))
                found = manifest.find("f:Identity", windows_msix.NAMESPACES)
                if {key: found.get(key) for key in ("Name", "Publisher", "Version", "ProcessorArchitecture")} != dict(
                        expected, ProcessorArchitecture=architecture):
                    raise PackageError("inner package identity differs for " + file_name)
                inner[architecture] = {"fileName": file_name, "sha256": digest, "bytes": len(data),
                                       "bundledSha256": windows_msix.sha256(data), "repacked": repacked}
    except (zipfile.BadZipFile, ET.ParseError, KeyError) as error:
        raise PackageError("bundle is unreadable: %s" % error) from error
    data = bundle_path.read_bytes()
    return {"name": bundle_path.name, "sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data),
            "signed": bool(signed), "identity": expected, "packages": inner,
            "packageFamilyName": name + "_" + windows_msix.publisher_id(publisher)}
