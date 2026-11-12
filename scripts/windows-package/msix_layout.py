"""Authenticate the runtime bundle exactly as the bundle job recorded it,
then write and recheck the package layout: the exact MSIX payload and its
package manifest."""
import io
import json
import pathlib
import platform
import re
import sys
import zipfile
import zlib

HERE = pathlib.Path(__file__).resolve().parent
if str(HERE.parent / "windows-bundle") not in sys.path:
    sys.path.insert(0, str(HERE.parent / "windows-bundle"))
import windows_pe
import windows_targets
from bundle_assembly import local_llm_library_path, verify_local_llm_payload
from bundle_policy import (
    APPLICATION,
    EXECUTABLES,
    BundleError,
    Policy,
    check_bundle_layout,
    check_bundle_path,
    resolve_closure,
    validate_executable,
)
from bundle_sources import APPLICATION_HOSTS, LOCAL_RUNTIME_PINS
from msix_assets import render_assets
from msix_identity import (
    FILE_NAME_FORBIDDEN,
    REPOSITORY,
    RESERVED_PACKAGE_DIRECTORIES,
    RESERVED_PACKAGE_FILES,
    PackageError,
    load_identity,
    package_identity,
    sha256,
    validate_publisher,
    validate_version,
)
from msix_manifest import render_manifest

PACKAGE_MANIFEST = "package-manifest.json"
APPX_MANIFEST = "AppxManifest.xml"


def pe_subsystem(data):
    image = windows_pe.PEImage(data)
    if image.optional_magic != 0x20b:
        raise PackageError("expected a PE32+ executable")
    value = image.subsystem
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
        raise PackageError("cannot read bundle-evidence.json: %s" % error) from error
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
                check_bundle_path(info.filename)
            entries = {info.filename: bundle.read(info) for info in infos}
    except (zipfile.BadZipFile, BundleError) as error:
        raise PackageError("bundle archive is invalid: %s" % error) from error
    manifest_bytes = entries.get("bundle-manifest.json")
    if manifest_bytes is None or sha256(manifest_bytes) != (evidence.get("manifest") or {}).get("sha256"):
        raise PackageError("bundle-manifest.json does not match bundle-evidence.json")
    manifest = json.loads(manifest_bytes)
    application = manifest.get("application") or {}
    executable = entries.get(APPLICATION)
    hashes = {name: sha256(entries[name]) for name in EXECUTABLES if name in entries}
    if (application.get("configuration") != "release" or application.get("appBuiltForTesting") is not False
            or application.get("sourceCommit") != commit or executable is None
            or application.get("executableSHA256") != sha256(executable)
            or (evidence.get("application") or {}).get("executableSHA256") != sha256(executable)
            or set(hashes) != set(EXECUTABLES) or application.get("executables") != hashes
            or (evidence.get("application") or {}).get("executables") != hashes):
        raise PackageError("bundle does not hold the recorded optimised production executable")
    policy = Policy.load()
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
        check_bundle_layout(sorted(entries), policy)
    except BundleError as error:
        raise PackageError(str(error)) from error
    reserved = [path for path in entries if _reserved_package_path(path)]
    if reserved:
        raise PackageError("bundle uses reserved package paths: " + ", ".join(sorted(reserved)))
    try:
        target = windows_targets.for_bundle_architecture((manifest.get("bundle") or {}).get("architecture"))
    except ValueError as error:
        raise PackageError(str(error)) from error
    architecture = target["name"]
    if (application.get("target") != target["swiftTriple"]
            or application.get("buildHost") != APPLICATION_HOSTS[architecture]):
        raise PackageError("bundle production source provenance differs from the architecture's build")
    try:
        images = {name: validate_executable(entries[name], name, architecture, policy)
                  for name in EXECUTABLES}
        for name in EXECUTABLES:
            if rows[name].get("source") != "application":
                raise PackageError(name + " must be attributed to the production application build")
        local = (manifest.get("sources") or {}).get("localInferenceRuntime")
        local_names = local.get("modules", []) if local else []
        if local:
            pins = json.loads(LOCAL_RUNTIME_PINS.read_text(encoding="utf-8"))
            pinned = pins["architectures"][architecture]
            variant = re.compile(pinned["cpuVariantPattern"]) if pinned["cpuVariantPattern"] else None
            if (local.get("architecture") != architecture or local.get("commit") != pins["whisperCpp"]["commit"]
                    or not set(pinned["requiredModules"]).issubset(local_names)
                    or len(set(local_names)) != len(local_names)
                    or any(name not in pinned["requiredModules"] and not (variant and variant.fullmatch(name))
                           for name in local_names)):
                raise PackageError("bundle local runtime differs from the architecture's pinned modules")
        local_llm = verify_local_llm_payload(
            entries, (manifest.get("sources") or {}).get("localLLMRuntime"), architecture)
        local_names = list(local_names) + (["llama.dll"] if local_llm else [])
        closure_policy = Policy(policy.data, local_names)

        def read_imports(name, category):
            path = local_llm_library_path(name, local_llm)
            if path not in entries:
                raise PackageError("bundled runtime module is missing: " + name)
            image = images.get(name) or windows_pe.PEImage(entries[path], name)
            if category != "application":
                if not image.runs_natively_on(architecture) or not image.is_dll:
                    raise PackageError("%s is not a native %s DLL (it is %s)" % (
                        name, architecture, image.architecture))
                if rows[path].get("source") != category:
                    raise PackageError("runtime source attribution differs for " + name)
            return image.imports(), image.delay_imports()

        closure = resolve_closure(EXECUTABLES, read_imports, closure_policy, sorted(local_names))
        dependencies = manifest.get("dependencies") or {}
        if (any(dependencies.get(key) != closure[key] for key in ("bundled", "system", "roots"))
                or dependencies.get("additionalRuntimeModules") != policy.additional):
            raise PackageError("bundle multi-root dependency closure or importer attribution differs from its PEs")
        expected_images = set(EXECUTABLES) | {
            local_llm_library_path(entry["name"], local_llm) for entry in closure["bundled"].values()}
        shipped_images = {name for name in entries if name.lower().endswith((".exe", ".dll"))}
        if shipped_images != expected_images:
            raise PackageError("bundle images differ from the exact production multi-root closure")
    except BundleError as error:
        raise PackageError(str(error)) from error
    return {"evidence": evidence, "manifest": manifest, "manifestSHA256": sha256(manifest_bytes),
            "entries": entries, "rows": rows, "commit": commit, "architecture": architecture,
            "archive": {"name": name, "sha256": archive_record["sha256"], "bytes": archive_record["bytes"]},
            "executableSHA256": sha256(executable), "subsystem": pe_subsystem(executable)}


# --- layout ------------------------------------------------------------------------------------
def _check_package_path(path):
    check_bundle_path(path)
    if FILE_NAME_FORBIDDEN.search(path):
        raise PackageError("package file names cannot contain <>\":%|?* or controls: " + path)
    return path


def build_layout(bundle_dir, output_dir, version, publisher=None, expected_commit=None,
                 identity=None, source_root=REPOSITORY):
    """Write ``output_dir/layout`` (the exact package payload) and its evidence."""
    identity = identity or load_identity()
    publisher = publisher or identity["identity"].get("developerPublisher")
    if publisher is None:
        raise PackageError("the %s channel needs --publisher: the signing certificate's exact subject"
                           % identity["channel"])
    publisher = validate_publisher(publisher)
    version = validate_version(version)
    bundle_dir, output_dir = pathlib.Path(bundle_dir).resolve(), pathlib.Path(output_dir).resolve()
    if bundle_dir == output_dir or bundle_dir in output_dir.parents or output_dir in bundle_dir.parents:
        raise PackageError("keep the bundle input and the package output separate")
    if output_dir.exists() and (not output_dir.is_dir() or any(output_dir.iterdir())):
        raise PackageError("package output must be a new or empty directory")
    bundle = verify_bundle(bundle_dir, expected_commit)
    architecture = bundle["architecture"]
    executable = identity["application"]["executable"]
    if executable not in bundle["entries"]:
        raise PackageError("the bundle does not contain " + executable)
    assets, asset_record = render_assets(identity, source_root)
    files = {path: (data, "bundle") for path, data in bundle["entries"].items()}
    for path, data in assets.items():
        if path.lower() in {existing.lower() for existing in files}:
            raise PackageError("generated asset collides with a bundle file: " + path)
        files[path] = (data, "generated-asset")
    files[APPX_MANIFEST] = (render_manifest(identity, version, publisher, architecture=architecture),
                            "generated-manifest")
    for path in files:
        _check_package_path(path)
    try:
        check_bundle_layout(sorted(files) + [PACKAGE_MANIFEST], Policy.load())
    except BundleError as error:
        raise PackageError(str(error)) from error
    rows = []
    for path in sorted(files):
        data, origin = files[path]
        row = {"path": path, "bytes": len(data), "sha256": sha256(data), "origin": origin}
        if origin == "bundle" and path in bundle["rows"]:
            row["bundleSource"] = bundle["rows"][path]["source"]
        rows.append(row)
    identity_record = package_identity(identity, version, publisher, architecture)
    package_manifest = {
        "schemaVersion": 1,
        "package": dict(identity_record, kind="unsigned Windows %s %s MSIX payload" % (
                            windows_targets.target(architecture)["displayName"], identity["channel"]), signed=False,
                        channel=identity["channel"], releaseTrain=None),
        "fileSystem": identity["fileSystem"],
        "capabilities": identity["capabilities"],
        "targetDeviceFamily": identity["targetDeviceFamily"],
        "executable": {"path": executable, "sha256": bundle["executableSHA256"], "subsystem": bundle["subsystem"]},
        "executables": {name: {"sha256": sha256(bundle["entries"][name]),
                               "subsystem": pe_subsystem(bundle["entries"][name])} for name in EXECUTABLES},
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
