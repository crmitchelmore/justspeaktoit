"""Authenticated inputs for the Windows runtime bundle: pinned downloads, the
production application build, and the Swift, Microsoft Visual C++, whisper.cpp
and native local LLM runtimes. Each loader checks its input against a pin or a
recorded hash and raises ``BundleError`` rather than returning untrusted bytes."""
import http.client
import json
import pathlib
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

import redistributables
import windows_pe
import windows_targets
from bundle_policy import EXECUTABLES, BundleError, check_bundle_path, digest_file, sha256, validate_executable

HERE = pathlib.Path(__file__).resolve().parent
if str(HERE.parent / "local-llm-runtime") not in sys.path:
    sys.path.insert(0, str(HERE.parent / "local-llm-runtime"))
import local_llm_package

# GitHub release assets and other pinned sources intermittently return 5xx or
# time out; an outage on 9 Nov lasted well over the old single attempt. The
# bytes are pinned by size and SHA-256, so retrying is safe.
NETWORK_RETRY_DELAYS = (10, 30, 60, 120)


def download_with_retry(source, timeout, path, limit, oversize):
    """Stream source into path, retrying transient network failures."""
    for delay in (*NETWORK_RETRY_DELAYS, None):
        try:
            with urllib.request.urlopen(source, timeout=timeout) as response, path.open("wb") as output:
                count = 0
                while chunk := response.read(1 << 20):
                    count += len(chunk)
                    if count > limit:
                        raise oversize()
                    output.write(chunk)
            return
        except urllib.error.HTTPError as error:
            if delay is None or (error.code < 500 and error.code != 429):
                raise
            reason = "HTTP %d" % error.code
        except (urllib.error.URLError, TimeoutError, ConnectionError, http.client.HTTPException) as error:
            if delay is None:
                raise
            reason = str(error)
        print("Download failed (%s); retrying in %ds" % (reason, delay), flush=True)
        time.sleep(delay)


LOCAL_RUNTIME_PINS = HERE.parent / "windows-local-runtime" / "dependencies.json"
# The build that supplies each architecture's production executable: the Mac
# cross-build for x64, the native Windows build for ARM64.
APPLICATION_HOSTS = {"x64": "Darwin", "arm64": "Windows"}
ALLOWED_DOWNLOAD_HOSTS = {"download.visualstudio.microsoft.com", "raw.githubusercontent.com"}


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
    download_with_retry(entry["url"], 120, temporary, entry["bytes"],
                        lambda: BundleError("download exceeded its pinned size: " + name))
    if temporary.stat().st_size != entry["bytes"] or digest_file(temporary) != entry["sha256"]:
        temporary.unlink(missing_ok=True)
        raise BundleError("downloaded file checksum mismatch: " + name)
    temporary.replace(destination)
    return destination


# --- application input ----------------------------------------------------------------
def load_application(app_dir, policy, architecture="x64"):
    metadata_path = app_dir / "app-build-metadata.json"
    if not metadata_path.is_file():
        raise BundleError("missing app-build-metadata.json in " + str(app_dir))
    metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    target = windows_targets.target(architecture)
    expectations = {"host": APPLICATION_HOSTS[architecture], "target": target["swiftTriple"],
                    "configuration": "release", "appBuiltForTesting": False}
    for key, value in expectations.items():
        if metadata.get(key) != value:
            raise BundleError("app metadata %s is %r; expected %r" % (key, metadata.get(key), value))
    executables = {}
    for name in EXECUTABLES:
        executable = app_dir / name
        if not executable.is_file() or executable.is_symlink():
            raise BundleError("missing production executable " + str(executable))
        data = executable.read_bytes()
        if sha256(data) != metadata.get("executables", {}).get(name):
            raise BundleError(name + " does not match the hash recorded by the build")
        validate_executable(data, name, architecture, policy)
        executables[name] = data
    resources = {}
    for directory in sorted(app_dir.iterdir()):
        if not directory.name.endswith(".resources") or directory.is_symlink() or not directory.is_dir():
            continue
        target = directory.name[:-len(".resources")]
        if target.endswith("Tests") or target == "SpeakTestSupport" or target.endswith("_SpeakTestSupport"):
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
    return {"metadata": metadata, "executables": executables, "resources": resources}


# --- Swift runtime source ---------------------------------------------------------------
def load_swift_runtime(runtime, lock_path=HERE / "swift-runtime-lock.json", architecture="x64"):
    """Authenticate an extracted Swift runtime directory against a lock for the pinned installer.

    x64 uses the cross-build cache's ``swift-windows`` directory and the
    committed lock; ARM64 uses pin-swift-runtime.py's ``--runtime-output`` and
    the lock it wrote, which must name the pinned ARM64 installer.
    """
    runtime = pathlib.Path(runtime)
    if not runtime.is_dir() or runtime.is_symlink() or not lock_path.is_file():
        raise BundleError("missing pinned Swift runtime provenance or runtime directory")
    # Authenticate against the reviewed source lock, never mutable metadata next
    # to the extracted DLLs. pin-swift-runtime.py reproduces the entire chain.
    source = json.loads(lock_path.read_text(encoding="utf-8"))
    swift_version, pinned, pin_file = windows_targets.swift_runtime_installer(architecture)
    installer = source.get("installer") or {}
    if (source.get("architecture") != architecture or source.get("swiftVersion") != swift_version
            or any(installer.get(key) != pinned[key] for key in ("name", "url", "sha256"))
            or not isinstance(installer.get("bytes"), int)
            or not windows_targets.installer_size_matches(pinned, installer["bytes"])):
        raise BundleError("Swift runtime lock does not match the pinned %s installer in %s" % (
            architecture, pin_file.relative_to(HERE.parent.parent)))
    layout = {row["path"]: row for row in source["files"]}
    if len(layout) != len(source["files"]):
        raise BundleError("duplicate Swift runtime lock path")
    return {"directory": runtime, "layout": layout, "payloads": source["payloads"], "installer": installer,
            "lockSHA256": digest_file(lock_path), "bootstrapManifestSHA256": source["bootstrapManifestSHA256"],
            "swiftVersion": swift_version, "pinFile": pin_file.relative_to(HERE.parent.parent).as_posix()}


def read_swift_module(source, name):
    row = source["layout"].get(name)
    path = source["directory"] / name
    if row is None or "/" in name or not path.is_file() or path.is_symlink():
        raise BundleError("Swift runtime package does not provide " + name)
    data = path.read_bytes()
    if len(data) != row["bytes"]:
        raise BundleError(name + " does not match the runtime package layout size")
    if sha256(data) != row["sha256"]:
        raise BundleError(name + " checksum differs from the authenticated runtime package")
    provenance = {"package": "rtl.msi", "cabinet": row["cabinet"], "fileKey": row["id"],
                  "installer": source["installer"]["name"], "swiftVersion": source["swiftVersion"]}
    return data, provenance


# --- Microsoft runtime source ------------------------------------------------------------
def load_microsoft_runtime(bundle_path, lock, log, architecture="x64"):
    """Read the architecture's runtime package from the pinned Visual C++ redistributable.

    Only DLLs a native process of ``architecture`` loads are offered to the
    import closure. The ARM64 package also installs x64 and ARM64EC DLLs for
    emulated programs; those are recorded as skipped and never bundled.
    """
    target = windows_targets.target(architecture)
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
    msi_payload = by_path.get(lock["packages"][target["visualCppPackage"]])
    if msi_payload is None:
        raise BundleError("bundle manifest lacks the %s runtime package" % target["displayName"])
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
    modules, skipped = {}, []
    for row in database.table("File"):
        cabinet_name = next(item["Cabinet"] for item in media if row["Sequence"] <= item["LastSequence"])
        cabinet, element = cabinets[cabinet_name]
        long_name = redistributables.long_name(row["FileName"])
        blob = cabinet.extract([row["File"]])[row["File"]]
        if len(blob) != row["FileSize"]:
            raise BundleError("extracted %s size differs from the MSI File table" % long_name)
        image = windows_pe.PEImage(blob, long_name)
        info = image.version_info() or {}
        if not image.is_dll or info.get("fileVersion") != row["Version"]:
            raise BundleError("extracted %s is not the %s runtime DLL" % (long_name, row["Version"]))
        if not image.runs_natively_on(architecture):
            skipped.append({"name": long_name, "architecture": image.architecture})
            continue
        modules[long_name.lower()] = {"name": long_name, "bytes": blob, "provenance": {
            "download": lock["name"], "downloadSHA256": lock["sha256"], "package": msi_payload.get("FilePath"),
            "packageSHA1": msi_payload.get("Hash").lower(), "packageSHA256": sha256(msi_bytes),
            "productName": properties.get("ProductName"), "productCode": properties.get("ProductCode"),
            "productVersion": properties.get("ProductVersion"), "cabinet": element.get("FilePath"),
            "cabinetSHA1": element.get("Hash").lower(), "fileKey": row["File"], "fileVersion": row["Version"],
            "installDirectory": components[row["Component_"]]["Directory_"], "imageArchitecture": image.architecture}}
    if not modules:
        raise BundleError("%s holds no native %s runtime DLL" % (msi_payload.get("FilePath"), target["displayName"]))
    log("Read %d %s runtime DLLs from %s (%s)%s" % (
        len(modules), target["displayName"], lock["name"], properties.get("ProductName"),
        "; skipped " + ", ".join("%s (%s)" % (item["name"], item["architecture"]) for item in skipped) if skipped else ""))
    return {"modules": modules, "version": version, "displayName": arp.get("DisplayName"),
            "productName": properties.get("ProductName"), "skipped": skipped}


# --- local inference runtime (whisper.cpp) -------------------------------------------------
def load_local_runtime(directory, pins_path=LOCAL_RUNTIME_PINS, architecture="x64"):
    """Authenticate a whisper.cpp runtime build against its manifest and the repository pins.

    The DLLs are built on Windows by scripts/windows-local-runtime/build-whisper-runtime.py.
    Every file must match the manifest's size and SHA-256 and be a native DLL
    for ``architecture``, and the manifest must name exactly that
    architecture's pinned commit, CMake arguments, Vulkan SDK (or none) and pin file.
    """
    directory = pathlib.Path(directory)
    pins_bytes = pins_path.read_bytes()
    pins = json.loads(pins_bytes)
    try:
        manifest = json.loads((directory / "runtime-manifest.json").read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise BundleError("cannot read the local runtime manifest: %s" % error) from error
    target = (pins.get("architectures") or {}).get(architecture)
    if target is None:
        raise BundleError("no whisper.cpp runtime is pinned for " + architecture)
    whisper, sdk = pins["whisperCpp"], target["vulkanSdk"]
    expectations = {"runtime": "whisper.cpp", "architecture": architecture, "version": whisper["version"],
                    "commit": whisper["commit"], "cmakeArguments": target["cmakeArguments"],
                    "pinsSHA256": sha256(pins_bytes.replace(b"\r\n", b"\n")),
                    "vulkanSdk": None if sdk is None else {key: sdk[key] for key in ("version", "sha256", "bytes")}}
    for key, value in expectations.items():
        if manifest.get(key) != value:
            raise BundleError("local runtime manifest %s is %r; expected %r" % (key, manifest.get(key), value))
    variant = re.compile(target["cpuVariantPattern"]) if target["cpuVariantPattern"] else None

    def is_variant(name):
        return variant is not None and variant.match(name) is not None

    modules = {}
    for row in manifest.get("files") or []:
        name = row.get("name")
        if (not isinstance(name, str) or pathlib.PurePosixPath(name).name != name or
                not (name in target["requiredModules"] or is_variant(name))):
            raise BundleError("unexpected local runtime file: %r" % (name,))
        path = directory / "runtime" / name
        if not path.is_file() or path.is_symlink():
            raise BundleError("local runtime file is missing: " + name)
        data = path.read_bytes()
        if len(data) != row.get("bytes") or sha256(data) != row.get("sha256"):
            raise BundleError("local runtime file does not match its manifest: " + name)
        image = windows_pe.PEImage(data, name)
        if not image.runs_natively_on(architecture) or not image.is_dll:
            raise BundleError("%s is not a native %s DLL (it is %s)" % (name, architecture, image.architecture))
        modules[name.lower()] = {"name": name, "bytes": data, "provenance": {
            "runtime": "whisper.cpp", "version": manifest["version"], "commit": manifest["commit"],
            "compiler": manifest.get("compiler"), "vulkanSdk": manifest["vulkanSdk"]["version"] if sdk else None,
            "builtBy": "scripts/windows-local-runtime/build-whisper-runtime.py"}}
    missing = sorted(set(name.lower() for name in target["requiredModules"]) - set(modules))
    if missing or sum(1 for name in modules if is_variant(name)) < target["minimumCpuVariants"]:
        raise BundleError("the local runtime is incomplete: " + (", ".join(missing) or "too few CPU variants"))
    licence = directory / "runtime" / "LICENSE-whisper.cpp.txt"
    if not licence.is_file() or digest_file(licence) != whisper["licenseSHA256"]:
        raise BundleError("the whisper.cpp licence is missing or differs from its pin")
    return {"modules": modules, "license": licence.read_bytes(), "manifest": manifest,
            "manifestSHA256": sha256((directory / "runtime-manifest.json").read_bytes())}


def load_local_llm_runtime(directory, architecture="x64"):
    try:
        return local_llm_package.read_directory(
            directory, "windows", "x86_64" if architecture == "x64" else architecture)
    except (OSError, ValueError) as error:
        raise BundleError("cannot authenticate the native local LLM runtime: " + str(error)) from error
