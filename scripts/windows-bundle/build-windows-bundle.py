#!/usr/bin/env python3
"""Assemble the self-contained, unsigned Windows developer runtime bundle.

Inputs are the Mac cross-build output (``build-windows-app.py``), the private
cross-build cache (for the Swift 6.2.3 runtime DLLs and their installer
provenance) and pinned official downloads (Microsoft's Visual C++ runtime and
licence texts). The output is a deterministic ZIP holding the production
``SpeakWindows.exe``, its SwiftPM resources, only the runtime DLLs reached from
the executable's static and delay-load import closure, licence notices and a
manifest of hashes and provenance. Compiler, SDK, header, import-library,
symbol, installer and test files are refused.
"""
import argparse
import fnmatch
import hashlib
import json
import os
import pathlib
import platform
import re
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
import zipfile
import zlib

HERE = pathlib.Path(__file__).resolve().parent
sys.dont_write_bytecode = True
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))
import redistributables  # noqa: E402
import windows_pe  # noqa: E402

CROSS = HERE.parent / "windows-cross"
APPLICATION = "SpeakWindows.exe"
ZIP_TIMESTAMP = (1980, 1, 1, 0, 0, 0)
RESERVED_NAMES = {"con", "prn", "aux", "nul"} | {"com%d" % n for n in range(1, 10)} | {"lpt%d" % n for n in range(1, 10)}
ALLOWED_DOWNLOAD_HOSTS = {"download.visualstudio.microsoft.com", "raw.githubusercontent.com"}
SYSTEM_MODULE, SWIFT_RUNTIME, MICROSOFT_RUNTIME, TEST_MODULE, UNKNOWN_MODULE = (
    "system", "swift-runtime", "microsoft-runtime", "test", "unknown")


class BundleError(Exception):
    """A bundle input violates the packaging policy; nothing is written."""


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def digest_file(path):
    hasher = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            hasher.update(chunk)
    return hasher.hexdigest()


class Log:
    def __init__(self, path=None):
        self.path = path
        if path is not None:
            path.write_text("")

    def __call__(self, message):
        print(message, flush=True)
        if self.path is not None:
            with self.path.open("a") as stream:
                stream.write(message + "\n")


# --- policy ---------------------------------------------------------------------
class Policy:
    def __init__(self, data):
        self.data = data
        self.system = {name.lower() for name in data["windowsSystemModules"]}
        self.api_sets = [re.compile(pattern) for pattern in data["windowsApiSetPatterns"]]
        self.swift = {name.lower(): name for name in data["swiftRuntimeModules"]}
        self.microsoft = {name.lower(): name for name in data["microsoftRuntimeModules"]}
        self.tests = {name.lower() for name in data["testModules"]}
        self.additional = [name for name in data["additionalRuntimeModules"]]
        self.forbidden = [pattern.lower() for pattern in data["forbiddenBundlePatterns"]]
        overlap = (self.system & set(self.swift)) | (self.system & set(self.microsoft)) | (set(self.swift) & set(self.microsoft))
        overlap |= self.tests & (self.system | set(self.swift) | set(self.microsoft))
        if overlap:
            raise BundleError("runtime policy lists a module in more than one category: " + ", ".join(sorted(overlap)))
        for name in self.additional:
            if self.classify(name) not in (SWIFT_RUNTIME, MICROSOFT_RUNTIME):
                raise BundleError("additionalRuntimeModules must name a pinned runtime module: " + name)

    @classmethod
    def load(cls, path=HERE / "runtime-policy.json"):
        return cls(json.loads(path.read_text()))

    def classify(self, module):
        lower = module.lower()
        if lower in self.tests:
            return TEST_MODULE
        if lower in self.system or any(pattern.match(lower) for pattern in self.api_sets):
            return SYSTEM_MODULE
        if lower in self.swift:
            return SWIFT_RUNTIME
        if lower in self.microsoft:
            return MICROSOFT_RUNTIME
        return UNKNOWN_MODULE

    def canonical(self, module):
        lower = module.lower()
        return self.swift.get(lower) or self.microsoft.get(lower) or module

    def forbids(self, path):
        lower = path.lower()
        name = lower.rsplit("/", 1)[-1]
        return any(fnmatch.fnmatchcase(lower, pattern) or fnmatch.fnmatchcase(name, pattern) for pattern in self.forbidden)


# --- dependency closure -----------------------------------------------------------
def resolve_closure(root, read_imports, policy):
    """Walk static and delay-load imports from ``root`` until only system modules remain.

    ``read_imports(name, category)`` returns ``(static, delayed)`` module name lists
    for the application (category ``"application"``) or a runtime module. The
    result records each bundled runtime module with its importers, each system
    module with its importers, and raises ``BundleError`` for test libraries or
    modules that no pinned runtime source provides.
    """
    bundled, system, queue = {}, {}, [(root, "application")]
    seen = {root.lower()}
    for name in policy.additional:
        lower = name.lower()
        bundled[lower] = {"name": policy.canonical(name), "source": policy.classify(name),
                          "importedBy": [{"importer": "runtime-policy", "kind": "runtime-loaded"}]}
        seen.add(lower)
        queue.append((policy.canonical(name), policy.classify(name)))
    while queue:
        importer, category = queue.pop(0)
        static, delayed = read_imports(importer, category)
        for kind, names in (("static", static), ("delay", delayed)):
            for module in names:
                lower = module.lower()
                found = policy.classify(module)
                if found == TEST_MODULE:
                    raise BundleError(importer + " imports the test library " + module +
                                      "; only the production executable may be bundled")
                if found == UNKNOWN_MODULE:
                    raise BundleError(importer + " imports " + module + ", which is neither a Windows system "
                                      "module nor a module of the pinned Swift or Microsoft runtimes")
                reference = {"importer": importer, "kind": kind}
                if found == SYSTEM_MODULE:
                    system.setdefault(lower, {"name": module, "importedBy": []})["importedBy"].append(reference)
                    continue
                entry = bundled.setdefault(lower, {"name": policy.canonical(module), "source": found, "importedBy": []})
                entry["importedBy"].append(reference)
                if lower not in seen:
                    seen.add(lower)
                    queue.append((entry["name"], found))
    return {"bundled": dict(sorted(bundled.items())), "system": dict(sorted(system.items()))}


# --- bundle path safety -------------------------------------------------------------
def check_bundle_path(path):
    if not path or path.startswith("/") or "\\" in path or ":" in path:
        raise BundleError("unsafe bundle path: " + repr(path))
    for part in path.split("/"):
        if part in ("", ".", "..") or part != part.strip() or part.endswith(".") or any(ord(c) < 32 for c in part):
            raise BundleError("unsafe bundle path component: " + repr(path))
        if part.split(".")[0].lower() in RESERVED_NAMES:
            raise BundleError("reserved Windows device name in bundle path: " + repr(path))
    return path


def check_bundle_layout(paths, policy):
    lowered = {}
    for path in paths:
        check_bundle_path(path)
        if policy.forbids(path):
            raise BundleError("policy forbids shipping " + path)
        key = path.lower()
        if key in lowered:
            raise BundleError("case-insensitive path collision: " + lowered[key] + " and " + path)
        lowered[key] = path
    directories = {"/".join(path.lower().split("/")[:depth]) for path in paths
                   for depth in range(1, len(path.split("/")))}
    clash = directories & set(lowered)
    if clash:
        raise BundleError("a file and a directory share a name: " + ", ".join(sorted(clash)))


# --- deterministic archive -----------------------------------------------------------
def write_deterministic_zip(path, entries):
    """Write ``{path: bytes}`` as a ZIP whose bytes depend only on its contents."""
    names = sorted(entries)
    with zipfile.ZipFile(path, "w") as archive:
        for name in names:
            info = zipfile.ZipInfo(name, date_time=ZIP_TIMESTAMP)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.create_system = 3
            info.external_attr = 0o100644 << 16
            archive.writestr(info, entries[name], compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)
    return names


# --- pinned downloads ---------------------------------------------------------------
def download(entry, directory):
    url = urllib.parse.urlsplit(entry["url"])
    if url.scheme != "https" or url.hostname not in ALLOWED_DOWNLOAD_HOSTS:
        raise BundleError("unexpected download source: " + entry["url"])
    name = entry["name"]
    if pathlib.PurePath(name).name != name:
        raise BundleError("download name must be a basename: " + name)
    directory.mkdir(parents=True, exist_ok=True)
    destination = directory / name
    if destination.exists():
        if destination.stat().st_size != entry["bytes"] or digest_file(destination) != entry["sha256"]:
            raise BundleError("cached download checksum mismatch: " + name)
        return destination
    temporary = destination.with_name(name + ".partial")
    print("Downloading pinned file: " + name, flush=True)
    with urllib.request.urlopen(entry["url"], timeout=120) as response, temporary.open("wb") as output:
        count = 0
        while chunk := response.read(1024 * 1024):
            count += len(chunk)
            if count > entry["bytes"]:
                raise BundleError("download exceeded its pinned size: " + name)
            output.write(chunk)
    if temporary.stat().st_size != entry["bytes"] or digest_file(temporary) != entry["sha256"]:
        temporary.unlink(missing_ok=True)
        raise BundleError("downloaded file checksum mismatch: " + name)
    temporary.replace(destination)
    return destination


# --- application input ----------------------------------------------------------------
def load_application(app_dir, policy):
    metadata_path = app_dir / "app-build-metadata.json"
    if not metadata_path.is_file():
        raise BundleError("missing app-build-metadata.json in " + str(app_dir))
    metadata = json.loads(metadata_path.read_text())
    expectations = {"host": "Darwin", "target": "x86_64-unknown-windows-msvc", "configuration": "release",
                    "appBuiltForTesting": False}
    for key, value in expectations.items():
        if metadata.get(key) != value:
            raise BundleError("app metadata %s is %r; expected %r" % (key, metadata.get(key), value))
    executable = app_dir / APPLICATION
    if not executable.is_file() or executable.is_symlink():
        raise BundleError("missing production executable " + str(executable))
    data = executable.read_bytes()
    recorded = metadata.get("executables", {}).get(APPLICATION)
    if sha256(data) != recorded:
        raise BundleError("SpeakWindows.exe does not match the hash recorded by the cross-build")
    image = windows_pe.PEImage(data, APPLICATION)
    if not image.is_x64 or image.is_dll:
        raise BundleError("SpeakWindows.exe is not a Windows x64 executable")
    for module in image.imports() + image.delay_imports():
        if policy.classify(module) == TEST_MODULE:
            raise BundleError("SpeakWindows.exe imports " + module + "; refusing a test-enabled build")
    resources = {}
    for directory in sorted(app_dir.iterdir()):
        if not directory.name.endswith(".resources") or directory.is_symlink() or not directory.is_dir():
            continue
        if directory.name[:-len(".resources")].endswith("Tests"):
            continue
        for path in sorted(directory.rglob("*")):
            relative = path.relative_to(app_dir).as_posix()
            if path.is_symlink():
                raise BundleError("symbolic link in resources: " + relative)
            if path.is_dir():
                continue
            if not path.is_file():
                raise BundleError("unsupported file type in resources: " + relative)
            resources[check_bundle_path(relative)] = path.read_bytes()
    return {"metadata": metadata, "executable": data, "resources": resources}


# --- Swift runtime source ---------------------------------------------------------------
def load_swift_runtime(cache):
    runtime = cache / "swift-windows"
    layout_path = cache / "windows-extraction" / "rtl-layout.json"
    manifest_path = cache / "windows-extraction" / "bootstrap" / "0"
    for path in (runtime, layout_path, manifest_path):
        if not path.exists():
            raise BundleError("cross-build cache lacks Swift runtime provenance: " + str(path))
    layout = {row["path"]: row for row in json.loads(layout_path.read_text())}
    payloads = {}
    for element in ET.parse(manifest_path).getroot().iter():
        if element.tag.endswith("}Payload") and element.get("FilePath") in ("rtl.msi", "rtl.cab"):
            payloads[element.get("FilePath")] = {"bytes": int(element.get("FileSize")),
                                                 "sha512": element.get("Hash").lower()}
    if set(payloads) != {"rtl.msi", "rtl.cab"}:
        raise BundleError("Swift installer manifest does not list the runtime package")
    installer = json.loads((CROSS / "dependencies.json").read_text())
    pinned = next(entry for entry in installer["downloads"] if entry["name"].endswith("-windows10.exe"))
    return {"directory": runtime, "layout": layout, "payloads": payloads, "installer": pinned,
            "swiftVersion": installer["swiftVersion"]}


def read_swift_module(source, name):
    row = source["layout"].get(name)
    path = source["directory"] / name
    if row is None or "/" in name or not path.is_file() or path.is_symlink():
        raise BundleError("Swift runtime package does not provide " + name)
    data = path.read_bytes()
    if len(data) != row["bytes"]:
        raise BundleError(name + " does not match the runtime package layout size")
    provenance = {"package": "rtl.msi", "cabinet": row["cabinet"], "fileKey": row["id"],
                  "installer": source["installer"]["name"], "swiftVersion": source["swiftVersion"]}
    return data, provenance


# --- Microsoft runtime source ------------------------------------------------------------
def load_microsoft_runtime(bundle_path, lock, log):
    data = bundle_path.read_bytes()
    containers = redistributables.burn_containers(data)
    if len(containers) != 2:
        raise BundleError("expected the UX and attached containers in " + bundle_path.name)
    (ux_offset, ux_size), (attached_offset, attached_size) = containers
    manifest_bytes = redistributables.Cabinet(data[ux_offset:ux_offset + ux_size], "ux").extract(["0"])["0"]
    manifest = ET.fromstring(manifest_bytes)
    attached_bytes = data[attached_offset:attached_offset + attached_size]
    registration = next(element for element in manifest.iter() if element.tag.endswith("}Registration"))
    arp = next(element for element in registration.iter() if element.tag.endswith("}Arp"))
    version = registration.get("Version")
    if version != lock["version"]:
        raise BundleError("redistributable version %s does not match the pinned %s" % (version, lock["version"]))
    container = next(element for element in manifest.iter()
                     if element.tag.endswith("}Container") and element.get("Attached") == "yes")
    if not redistributables.payload_digest(attached_bytes, container.get("Hash")):
        raise BundleError("attached container hash does not match the bundle manifest")
    payloads = {element.get("Id"): element for element in manifest.iter()
                if element.tag.endswith("}Payload") and element.get("Container") == "WixAttachedContainer"}
    by_path = {element.get("FilePath"): element for element in payloads.values()}
    msi_payload = by_path.get(lock["packages"]["minimum"])
    if msi_payload is None:
        raise BundleError("bundle manifest lacks the x64 minimum runtime package")
    package = next(element for element in manifest.iter() if element.tag.endswith("}MsiPackage") and any(
        child.tag.endswith("}PayloadRef") and child.get("Id") == msi_payload.get("Id") for child in element))
    referenced = [payloads[child.get("Id")] for child in package if child.tag.endswith("}PayloadRef")]
    wanted = {element.get("SourcePath") for element in referenced}
    cabinet = redistributables.Cabinet(attached_bytes, "attached")
    extracted = cabinet.extract(wanted)
    for element in referenced:
        blob = extracted[element.get("SourcePath")]
        if len(blob) != int(element.get("FileSize")) or not redistributables.payload_digest(blob, element.get("Hash")):
            raise BundleError("payload does not match the bundle manifest: " + element.get("FilePath"))
    msi_bytes = extracted[msi_payload.get("SourcePath")]
    database = redistributables.MsiDatabase(redistributables.CompoundFile(msi_bytes, "minimum").streams(), "minimum")
    properties = {row["Property"]: row["Value"] for row in database.table("Property")}
    media = sorted(database.table("Media"), key=lambda row: row["LastSequence"])
    cabinets = {}
    for row in media:
        name = row["Cabinet"] or ""
        if name.startswith("#") or "/" in name or "\\" in name:
            raise BundleError("unsupported MSI media entry: " + name)
        element = next((item for item in referenced if item.get("FilePath").endswith("\\" + name)), None)
        if element is None:
            raise BundleError("package cabinet missing from the bundle: " + name)
        cabinets[name] = (redistributables.Cabinet(extracted[element.get("SourcePath")], name), element)
    components = {row["Component"]: row for row in database.table("Component")}
    modules = {}
    for row in database.table("File"):
        cabinet_name = next(item["Cabinet"] for item in media if row["Sequence"] <= item["LastSequence"])
        cabinet, element = cabinets[cabinet_name]
        long_name = redistributables.long_name(row["FileName"])
        blob = cabinet.extract([row["File"]])[row["File"]]
        if len(blob) != row["FileSize"]:
            raise BundleError("extracted %s size differs from the MSI File table" % long_name)
        image = windows_pe.PEImage(blob, long_name)
        info = image.version_info() or {}
        if not image.is_x64 or not image.is_dll or info.get("fileVersion") != row["Version"]:
            raise BundleError("extracted %s is not the x64 %s runtime DLL" % (long_name, row["Version"]))
        modules[long_name.lower()] = {"name": long_name, "bytes": blob, "provenance": {
            "download": lock["name"], "downloadSHA256": lock["sha256"], "package": msi_payload.get("FilePath"),
            "packageSHA1": msi_payload.get("Hash").lower(), "packageSHA256": sha256(msi_bytes),
            "productName": properties.get("ProductName"), "productCode": properties.get("ProductCode"),
            "productVersion": properties.get("ProductVersion"), "cabinet": element.get("FilePath"),
            "cabinetSHA1": element.get("Hash").lower(), "fileKey": row["File"], "fileVersion": row["Version"],
            "installDirectory": components[row["Component_"]]["Directory_"]}}
    log("Read %d x64 runtime DLLs from %s (%s)" % (len(modules), lock["name"], arp.get("DisplayName")))
    return {"modules": modules, "version": version, "displayName": arp.get("DisplayName"),
            "productName": properties.get("ProductName")}


# --- llvm-readobj cross-check ---------------------------------------------------------------
def parse_llvm_readobj_imports(text):
    static, delayed, section = [], [], None
    for line in text.splitlines():
        stripped = line.strip()
        if stripped == "Import {":
            section = static
        elif stripped == "DelayImport {":
            section = delayed
        elif stripped == "}":
            section = None
        elif section is not None and stripped.startswith("Name: "):
            section.append(stripped[len("Name: "):])
    return static, delayed


def cross_check_with_llvm(tool, name, data, image, log):
    with tempfile.TemporaryDirectory(prefix="jsti-bundle-readobj-") as scratch:
        path = pathlib.Path(scratch) / name
        path.write_bytes(data)
        text = subprocess.run([str(tool), "--coff-imports", str(path)], check=True, capture_output=True,
                              text=True).stdout
    static, delayed = parse_llvm_readobj_imports(text)
    expected = ([m.lower() for m in image.imports()], [m.lower() for m in image.delay_imports()])
    observed = ([m.lower() for m in static], [m.lower() for m in delayed])
    if expected != observed:
        raise BundleError("llvm-readobj import tables differ from the Python reader for " + name)
    log("llvm-readobj confirmed %d static and %d delay-load imports for %s" % (len(static), len(delayed), name))


# --- assembly ------------------------------------------------------------------------------
def readme_text(metadata, closure_names, microsoft):
    commit = metadata.get("sourceCommit") or "main"
    return "\n".join([
        "Just Speak to It - Windows x64 developer runtime bundle",
        "",
        "This is an unsigned developer build, not an installer, signed release or",
        "automatic-update channel. It runs from this folder on 64-bit Windows 10 or",
        "later without installing the Swift toolchain or Visual C++ redistributable:",
        "the runtime DLLs the application imports sit beside SpeakWindows.exe.",
        "",
        "Run SpeakWindows.exe, or pass --self-test / --ui-smoke-test. The smoke tests",
        "use no microphone and no real provider API key. Settings and recordings are",
        "stored under %LOCALAPPDATA%\\JustSpeakToIt. Because the executable is not",
        "code-signed, Windows SmartScreen may ask for confirmation before it runs.",
        "",
        "Bundled runtime: Swift 6.2.3 (" + ", ".join(name for name in closure_names if not name.lower().startswith(("msvcp", "vcruntime", "concrt", "vccorlib", "vcamp", "vcomp"))) + ")",
        "and " + microsoft["displayName"] + ".",
        "",
        "bundle-manifest.json lists every file with its SHA-256 and origin;",
        "THIRD-PARTY-NOTICES.txt and the licenses folder hold the licence terms.",
        "",
        "Current parity limits and verification evidence:",
        "https://github.com/crmitchelmore/justspeaktoit/blob/" + commit + "/Docs/windows-runtime-bundle.md",
        "",
    ])


def notices_text(app_license_name, swift_files, microsoft_files, microsoft, lock, licenses):
    lines = ["THIRD-PARTY NOTICES", "", "Just Speak to It is distributed under the MIT License (licenses/" + app_license_name + ").", ""]
    swift_license = next(entry for entry in licenses if entry["name"] == "LICENSE-swift.txt")
    lines += ["Swift 6.2.3 runtime (swift.org): " + ", ".join(swift_files),
              "  Licence: " + swift_license["license"] + " (licenses/LICENSE-swift.txt)",
              "  Source: official swift-6.2.3-RELEASE Windows installer runtime package (rtl.msi), pinned in scripts/windows-cross/dependencies.json", ""]
    icu = next((entry for entry in licenses if entry["name"] == "LICENSE-icu.txt"), None)
    if icu is not None:
        lines += ["_FoundationICU.dll additionally contains " + icu["covers"].split(" compiled")[0] + ":",
                  "  Licence: " + icu["license"] + " (licenses/LICENSE-icu.txt)", ""]
    lines += [microsoft["displayName"] + ": " + ", ".join(microsoft_files),
              "  Files are unmodified copies from Microsoft's official " + lock["name"] + " (" + microsoft["productName"] + ").",
              "  Redistributed under the Visual Studio 2022 Community licence's Distributable Code terms for this open-source application:",
              "  https://learn.microsoft.com/en-us/visualstudio/releases/2022/redistribution",
              "  https://visualstudio.microsoft.com/license-terms/vs2022-ga-community/",
              "  Runtime licence terms: https://aka.ms/VCRedistLicense (licenses/NOTICE-microsoft-visual-cpp-runtime.txt)", ""]
    lines += ["Windows operating-system modules (kernel32, user32, the Universal CRT and other API sets) are not redistributed.", ""]
    return "\n".join(lines)


def microsoft_notice_text(microsoft, lock, files):
    lines = ["Microsoft Visual C++ Runtime files included in this bundle", "",
             "Package: " + microsoft["displayName"], "Product: " + microsoft["productName"],
             "Official download: " + lock["url"], "Permalink: " + lock["permalink"],
             "SHA-256: " + lock["sha256"], "Size: %d bytes" % lock["bytes"], "", "Files:"]
    for name, module in files:
        provenance = module["provenance"]
        lines.append("  %s  version %s  SHA-256 %s" % (name, provenance["fileVersion"], sha256(module["bytes"])))
    lines += ["", "These files are unmodified. Microsoft permits licensed Visual Studio users to copy and distribute",
              "the Visual C++ Runtime files with their programs; see",
              "https://learn.microsoft.com/en-us/visualstudio/releases/2022/redistribution and",
              "https://visualstudio.microsoft.com/license-terms/vs2022-ga-community/. The runtime's licence terms",
              "are published at https://aka.ms/VCRedistLicense. The download was read as data only: no installer,",
              "MSI package or custom action was executed while extracting these files.", ""]
    return "\n".join(lines)


def assemble(application, swift, microsoft, licenses, app_license, policy, lock, cross_check, log):
    """Return ``(entries, manifest)``: bundle bytes keyed by path, and the manifest document."""
    executable = application["executable"]
    images = {}

    def read_imports(name, category):
        if category == "application":
            image = windows_pe.PEImage(executable, name)
        elif category == SWIFT_RUNTIME:
            image = windows_pe.PEImage(read_swift_module(swift, name)[0], name)
        elif category == MICROSOFT_RUNTIME:
            module = microsoft["modules"].get(name.lower())
            if module is None:
                raise BundleError("the pinned Visual C++ redistributable does not provide " + name)
            image = windows_pe.PEImage(module["bytes"], name)
        else:
            raise BundleError("cannot read imports for " + name)
        images[name] = image
        return image.imports(), image.delay_imports()

    closure = resolve_closure(APPLICATION, read_imports, policy)
    entries = {APPLICATION: executable}
    files = [{"path": APPLICATION, "bytes": len(executable), "sha256": sha256(executable), "source": "application"}]
    for relative, data in sorted(application["resources"].items()):
        entries[relative] = data
        files.append({"path": relative, "bytes": len(data), "sha256": sha256(data), "source": "application-resources"})
    swift_files, microsoft_files = [], []
    for lower, entry in closure["bundled"].items():
        name = entry["name"]
        if entry["source"] == SWIFT_RUNTIME:
            data, provenance = read_swift_module(swift, name)
            swift_files.append(name)
        else:
            module = microsoft["modules"][lower]
            data, provenance = module["bytes"], module["provenance"]
            microsoft_files.append(name)
        image = images.get(name) or windows_pe.PEImage(data, name)
        if not image.is_x64 or not image.is_dll:
            raise BundleError(name + " is not an x64 DLL")
        version = image.version_info() or {}
        entries[name] = data
        files.append({"path": name, "bytes": len(data), "sha256": sha256(data), "source": entry["source"],
                      "fileVersion": version.get("fileVersion"), "provenance": provenance})
    if cross_check is not None:
        for name in [APPLICATION] + swift_files + microsoft_files:
            cross_check_with_llvm(cross_check, name, entries[name], images.get(name) or windows_pe.PEImage(entries[name], name), log)
    license_names = []
    for entry in licenses:
        path = "licenses/" + entry["name"]
        entries[path] = entry["data"]
        files.append({"path": path, "bytes": len(entry["data"]), "sha256": sha256(entry["data"]), "source": "license",
                      "provenance": {"url": entry["url"], "license": entry["license"], "covers": entry["covers"]}})
        license_names.append(entry["name"])
    app_license_name = "LICENSE-JustSpeakToIt.txt"
    generated = {
        "licenses/" + app_license_name: app_license,
        "licenses/NOTICE-microsoft-visual-cpp-runtime.txt": microsoft_notice_text(
            microsoft, lock, [(name, microsoft["modules"][name.lower()]) for name in microsoft_files]).encode(),
        "THIRD-PARTY-NOTICES.txt": notices_text(app_license_name, swift_files, microsoft_files, microsoft, lock, licenses).encode(),
        "README.txt": readme_text(application["metadata"], swift_files + microsoft_files, microsoft).encode(),
    }
    for path, data in generated.items():
        entries[path] = data
        files.append({"path": path, "bytes": len(data), "sha256": sha256(data),
                      "source": "application-license" if path.endswith(app_license_name) else "generated"})
    files.sort(key=lambda item: item["path"])
    metadata = application["metadata"]
    manifest = {
        "schemaVersion": 1,
        "bundle": {"kind": "unsigned Windows x64 developer runtime bundle", "architecture": "x86_64",
                   "requires": "64-bit Windows 10 or later; the Universal CRT and other Windows modules come from the operating system",
                   "notInstaller": True, "codeSigned": False},
        "application": {"sourceCommit": metadata.get("sourceCommit"), "configuration": metadata.get("configuration"),
                        "target": metadata.get("target"), "appBuiltForTesting": metadata.get("appBuiltForTesting"),
                        "executableSHA256": sha256(executable), "swiftCompiler": metadata.get("swiftCompiler"),
                        "nativeCompiler": metadata.get("nativeCompiler")},
        "files": files,
        "dependencies": {"bundled": closure["bundled"], "system": closure["system"],
                         "additionalRuntimeModules": policy.additional},
        "sources": {
            "swiftRuntime": {"installer": swift["installer"], "payloads": swift["payloads"], "swiftVersion": swift["swiftVersion"]},
            "microsoftRuntime": {"download": {key: lock[key] for key in ("name", "url", "sha256", "bytes", "permalink", "version")},
                                 "displayName": microsoft["displayName"], "productName": microsoft["productName"]},
            "licenses": [{key: entry[key] for key in ("name", "url", "sha256", "bytes", "license", "covers")} for entry in licenses],
        },
        "policy": policy.data,
        "verification": {"importReader": "windows_pe.py static and delay-load import directories",
                         "llvmReadobjCrossCheck": cross_check is not None,
                         "windowsEvidence": "scripts/windows-bundle/verify-windows-bundle.ps1 runs the bundle with an isolated PATH and records loaded modules"},
    }
    check_bundle_layout(sorted(entries) + ["bundle-manifest.json"], policy)
    return entries, manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=pathlib.Path, help="build-windows-app.py output directory")
    parser.add_argument("--cache", required=True, type=pathlib.Path, help="private cross-build cache (read only)")
    parser.add_argument("--downloads", required=True, type=pathlib.Path, help="writable directory for pinned downloads")
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--source-root", type=pathlib.Path, default=HERE.parent.parent)
    parser.add_argument("--llvm-readobj", type=pathlib.Path, help="cross-check import tables with llvm-readobj")
    args = parser.parse_args()
    app, cache, output = args.app.resolve(), args.cache.resolve(), args.output.resolve()
    if cache == output or cache in output.parents or output in cache.parents or app in output.parents or output in app.parents:
        raise SystemExit("Keep the app output, private cache and bundle output separate")
    output.mkdir(parents=True, exist_ok=True)
    log = Log(output / "bundle-build.log")
    policy = Policy.load()
    lock = json.loads((HERE / "dependencies.json").read_text())
    application = load_application(app, policy)
    swift = load_swift_runtime(cache)
    downloads = args.downloads.resolve()
    microsoft = load_microsoft_runtime(download(lock["microsoftRuntime"], downloads), lock["microsoftRuntime"], log)
    licenses = []
    for entry in lock["licenses"]:
        path = download(entry, downloads)
        licenses.append(dict(entry, data=path.read_bytes()))
    app_license_path = args.source_root / "LICENSE"
    app_license = app_license_path.read_bytes()
    if b"MIT License" not in app_license:
        raise BundleError("unexpected application licence at " + str(app_license_path))
    cross_check = args.llvm_readobj.resolve() if args.llvm_readobj else None
    if cross_check is not None and not cross_check.is_file():
        raise BundleError("llvm-readobj not found at " + str(cross_check))
    entries, manifest = assemble(application, swift, microsoft, licenses, app_license, policy,
                                 lock["microsoftRuntime"], cross_check, log)
    manifest_bytes = (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode()
    entries["bundle-manifest.json"] = manifest_bytes
    commit = manifest["application"]["sourceCommit"]
    name = "justspeaktoit-windows-x64-developer-" + (commit[:7] if commit else "local") + ".zip"
    archive = output / name
    names = write_deterministic_zip(archive, entries)
    archive_digest = digest_file(archive)
    (output / "bundle-manifest.json").write_bytes(manifest_bytes)
    evidence = {
        "schemaVersion": 1,
        "zip": {"name": name, "sha256": archive_digest, "bytes": archive.stat().st_size, "entries": len(names)},
        "manifest": {"name": "bundle-manifest.json", "sha256": sha256(manifest_bytes)},
        "application": {"sourceCommit": commit, "executableSHA256": manifest["application"]["executableSHA256"]},
        "bundledModules": [entry["name"] for entry in manifest["dependencies"]["bundled"].values()],
        "host": {"system": platform.system(), "machine": platform.machine(), "python": platform.python_version(),
                 "zlib": zlib.ZLIB_RUNTIME_VERSION},
        "llvmReadobjCrossCheck": cross_check is not None,
        "runtimeStatus": "Windows execution with an isolated PATH remains required",
    }
    (output / "bundle-evidence.json").write_text(json.dumps(evidence, indent=2, sort_keys=True) + "\n")
    log("Bundled %d files into %s (%s)" % (len(names), name, archive_digest))
    log("Runtime modules: " + ", ".join(evidence["bundledModules"]))


if __name__ == "__main__":
    try:
        main()
    except (BundleError, redistributables.ExtractionError, windows_pe.PEFormatError) as error:
        raise SystemExit("windows bundle: " + str(error))
