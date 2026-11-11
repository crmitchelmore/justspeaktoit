"""Synthetic bundles and packages shared by the Windows MSIX tests.

A plain module rather than a test file, so test modules can share it without
unittest collecting any test twice.
"""
import hashlib
import importlib.util
import json
import pathlib
import sys
import urllib.parse
import xml.etree.ElementTree as ET
import zipfile

HERE = pathlib.Path(__file__).resolve().parent
sys.dont_write_bytecode = True
sys.path.insert(0, str(HERE))
import windows_msix  # noqa: E402


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# The bundle tests already build minimal PE32+ images; reuse them.
BUNDLE_TESTS = load("windows_bundle_tests", HERE.parent / "windows-bundle" / "test_windows_bundle.py")
BUILD = windows_msix.BUNDLE
COMMIT = "0123456789abcdef0123456789abcdef01234567"


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def make_bundle(directory, commit=COMMIT, mutate=None, exe_imports=("swiftCore.dll", "KERNEL32.dll"),
                architecture="x64"):
    """Write a bundle directory shaped exactly like build-windows-bundle.py output."""
    directory = pathlib.Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    target = windows_msix.windows_targets.target(architecture)
    machine = target["processMachine"]
    executable = BUNDLE_TESTS.build_pe(imports=exe_imports, machine=machine, subsystem=2)
    cli = BUNDLE_TESTS.build_pe(imports=["swiftCore.dll", "KERNEL32.dll"], machine=machine)
    entries = {
        "SpeakWindows.exe": executable,
        "speak.exe": cli,
        "swiftCore.dll": BUNDLE_TESTS.build_pe(imports=["KERNEL32.dll"], dll=True, machine=machine),
        "SpeakApp_SpeakCore.resources/ReleaseNotes.json": b'{"entries": [{"version": "1"}]}',
        # Larger than one 64 KiB block, so block maps have several blocks.
        "SpeakApp_SpeakCore.resources/Large.bin": bytes(range(256)) * 700,
        "licenses/LICENSE-JustSpeakToIt.txt": b"MIT License\n",
        "README.txt": b"Developer bundle\n",
    }
    sources = {"SpeakWindows.exe": "application", "speak.exe": "application",
               "swiftCore.dll": "swift-runtime", "README.txt": "generated",
               "licenses/LICENSE-JustSpeakToIt.txt": "application-license"}
    # Invalid executable-import fixtures still need a producer-shaped graph;
    # the consumer must re-read their PEs rather than trust this graph.
    graph_images = dict(entries, **{"SpeakWindows.exe": BUNDLE_TESTS.build_pe(
        imports=["swiftCore.dll", "KERNEL32.dll"], machine=machine)})
    def read_imports(name, category):
        image = windows_msix.windows_pe.PEImage(graph_images[name], name)
        return image.imports(), image.delay_imports()
    closure = BUILD.resolve_closure(BUILD.EXECUTABLES, read_imports, BUILD.Policy.load())
    manifest = {
        "schemaVersion": 1,
        "bundle": {"kind": "unsigned Windows %s developer runtime bundle" % target["displayName"],
                   "architecture": target["bundleArchitecture"], "notInstaller": True, "codeSigned": False},
        "application": {"sourceCommit": commit, "configuration": "release", "appBuiltForTesting": False,
                        "executableSHA256": sha256(executable),
                        "executables": {"SpeakWindows.exe": sha256(executable), "speak.exe": sha256(cli)},
                        "target": target["swiftTriple"], "buildHost": BUILD.APPLICATION_HOSTS[architecture]},
        "dependencies": dict(closure, additionalRuntimeModules=BUILD.Policy.load().additional),
        "policy": BUILD.Policy.load().data,
    }
    if mutate is not None:
        mutate(entries, manifest)
    manifest["files"] = [{"path": path, "bytes": len(data), "sha256": sha256(data),
                          "source": sources.get(path, "application-resources")}
                         for path, data in sorted(entries.items()) if path != "bundle-manifest.json"]
    return write_bundle(directory, entries, manifest, architecture)


def write_bundle(directory, entries, manifest, architecture):
    directory.mkdir(parents=True, exist_ok=True)
    commit = manifest["application"]["sourceCommit"]
    manifest_bytes = (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode()
    entries["bundle-manifest.json"] = manifest_bytes
    archive = directory / ("justspeaktoit-windows-%s-developer-%s.zip" % (architecture, commit[:7]))
    BUILD.write_deterministic_zip(archive, entries)
    data = archive.read_bytes()
    evidence = {"schemaVersion": 1,
                "zip": {"name": archive.name, "sha256": sha256(data), "bytes": len(data), "entries": len(entries)},
                "manifest": {"name": "bundle-manifest.json", "sha256": sha256(manifest_bytes)},
                "application": {"sourceCommit": commit,
                                "executableSHA256": manifest["application"]["executableSHA256"],
                                "executables": manifest["application"]["executables"]}}
    (directory / "bundle-evidence.json").write_text(json.dumps(evidence, indent=2), encoding="utf-8")
    return directory


def build_blockmap(files):
    namespace = windows_msix.BLOCKMAP_NAMESPACE
    root = ET.Element("{%s}BlockMap" % namespace, HashMethod=windows_msix.SHA256_METHOD)
    for name, data in sorted(files.items()):
        element = ET.SubElement(root, "{%s}File" % namespace, Name=name.replace("/", "\\"), Size=str(len(data)),
                                LfhSize="30")
        for value in windows_msix.block_hashes(data):
            ET.SubElement(element, "{%s}Block" % namespace, Hash=value)
    return ET.tostring(root, xml_declaration=True, encoding="utf-8")


def make_package(layout, path, signed=False, extra=None, drop=None, blockmap=None, replace=None, listed_extra=None):
    """Write an .msix-shaped archive as MakeAppx (and SignTool) would, from a layout directory.

    ``listed_extra`` adds parts that the block map also lists, as SignTool does
    for its code integrity catalogue.
    """
    files = {item.relative_to(layout).as_posix(): item.read_bytes() for item in layout.rglob("*") if item.is_file()}
    for name in drop or ():
        files.pop(name)
    listed = dict(files)
    listed.update(listed_extra or {})
    files.update(replace or {})
    files.update(listed_extra or {})
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
        for name, data in sorted(files.items()):
            archive.writestr(urllib.parse.quote(name), data)
        for name, data in (extra or {}).items():
            archive.writestr(name, data)
        archive.writestr("AppxBlockMap.xml", blockmap if blockmap is not None else build_blockmap(listed))
        archive.writestr("[Content_Types].xml",
                         b'<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>')
        if signed:
            archive.writestr("AppxSignature.p7x", b"PKCX synthetic signature")
    return path
