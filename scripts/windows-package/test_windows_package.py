#!/usr/bin/env python3
"""Unit tests for the Windows developer MSIX tooling; no downloads, caches or Windows APIs."""
import copy
import hashlib
import importlib.util
import json
import pathlib
import struct
import sys
import tempfile
import unittest
import urllib.parse
import xml.etree.ElementTree as ET
import zipfile

HERE = pathlib.Path(__file__).resolve().parent
sys.dont_write_bytecode = True
sys.path.insert(0, str(HERE))
import lifecycle_support  # noqa: E402
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


def make_bundle(directory, commit=COMMIT, mutate=None, exe_imports=("swiftCore.dll", "KERNEL32.dll")):
    """Write a bundle directory shaped exactly like build-windows-bundle.py output."""
    directory = pathlib.Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    executable = BUNDLE_TESTS.build_pe(imports=exe_imports)
    entries = {
        "SpeakWindows.exe": executable,
        "swiftCore.dll": BUNDLE_TESTS.build_pe(imports=["KERNEL32.dll"], dll=True),
        "SpeakApp_SpeakCore.resources/ReleaseNotes.json": b'{"entries": [{"version": "1"}]}',
        # Larger than one 64 KiB block, so block maps have several blocks.
        "SpeakApp_SpeakCore.resources/Large.bin": bytes(range(256)) * 700,
        "licenses/LICENSE-JustSpeakToIt.txt": b"MIT License\n",
        "README.txt": b"Developer bundle\n",
    }
    sources = {"SpeakWindows.exe": "application", "swiftCore.dll": "swift-runtime", "README.txt": "generated",
               "licenses/LICENSE-JustSpeakToIt.txt": "application-license"}
    manifest = {
        "schemaVersion": 1,
        "bundle": {"kind": "unsigned Windows x64 developer runtime bundle", "notInstaller": True, "codeSigned": False},
        "application": {"sourceCommit": commit, "configuration": "release", "appBuiltForTesting": False,
                        "executableSHA256": sha256(executable)},
        "dependencies": {"bundled": {"swiftcore.dll": {"name": "swiftCore.dll", "source": "swift-runtime",
                                                       "importedBy": [{"importer": "SpeakWindows.exe",
                                                                       "kind": "static"}]}},
                         "system": {}},
        "policy": BUILD.Policy.load().data,
    }
    if mutate is not None:
        mutate(entries, manifest)
    manifest["files"] = [{"path": path, "bytes": len(data), "sha256": sha256(data),
                          "source": sources.get(path, "application-resources")}
                         for path, data in sorted(entries.items()) if path != "bundle-manifest.json"]
    manifest_bytes = (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode()
    entries["bundle-manifest.json"] = manifest_bytes
    archive = directory / ("justspeaktoit-windows-x64-developer-%s.zip" % commit[:7])
    BUILD.write_deterministic_zip(archive, entries)
    data = archive.read_bytes()
    evidence = {"schemaVersion": 1,
                "zip": {"name": archive.name, "sha256": sha256(data), "bytes": len(data), "entries": len(entries)},
                "manifest": {"name": "bundle-manifest.json", "sha256": sha256(manifest_bytes)},
                "application": {"sourceCommit": commit, "executableSHA256": sha256(executable)}}
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


def make_package(layout, path, signed=False, extra=None, drop=None, blockmap=None, replace=None):
    """Write an .msix-shaped archive as MakeAppx would, from a layout directory."""
    files = {item.relative_to(layout).as_posix(): item.read_bytes() for item in layout.rglob("*") if item.is_file()}
    for name in drop or ():
        files.pop(name)
    listed = dict(files)
    files.update(replace or {})
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


class IdentityTests(unittest.TestCase):
    def test_developer_identity_is_separate_from_every_release_train(self):
        identity = windows_msix.load_identity()
        self.assertEqual(identity["channel"], "developer")
        self.assertIsNone(identity["releaseTrain"])
        trains = json.loads((windows_msix.REPOSITORY / "Sources/SpeakCore/Resources/ReleaseTrains.json").read_text(encoding="utf-8"))
        claimed = {value for train in trains.values() for value in train.values()}
        for value in (identity["identity"]["name"], identity["presentation"]["displayName"],
                      identity["application"]["executionAlias"][:-4]):
            self.assertNotIn(value, claimed)
        self.assertIn("Not an Alpha or Stable release", identity["presentation"]["description"])

    def test_publisher_id_matches_windows_for_known_publishers(self):
        self.assertEqual(windows_msix.publisher_id(
            "CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US"), "8wekyb3d8bbwe")
        self.assertEqual(windows_msix.publisher_id(
            "CN=Microsoft Windows, O=Microsoft Corporation, L=Redmond, S=Washington, C=US"), "cw5n1h2txyewy")

    def test_versions_follow_the_manifest_schema(self):
        for version in ("0.0.1.0", "1.2.3.4", "65535.65535.65535.65535", "0.0.42.1"):
            self.assertEqual(windows_msix.validate_version(version), version)
        for version in ("1.2.3", "1.2.3.4.5", "65536.0.0.0", "01.0.0.0", "-1.0.0.0", " 1.0.0.0", "1.0.0.0 ", "", None):
            with self.assertRaises(windows_msix.PackageError):
                windows_msix.validate_version(version)

    def test_publishers_and_names_follow_the_manifest_schema(self):
        for publisher in ("CN=Just Speak to It Developer", "CN=Contoso Software, O=Contoso Corporation, C=US",
                          'CN="Quoted, Name", C=GB', "CN=Example, OID.2.25.311729368913984317654407730594956997722=1"):
            self.assertEqual(windows_msix.validate_publisher(publisher), publisher)
        for publisher in ("Just Speak", "CN=", "CN=a,O=b", "XX=Example", " CN=Example", "CN=Line\nBreak"):
            with self.assertRaises(windows_msix.PackageError):
                windows_msix.validate_publisher(publisher)
        for name in ("ab", "a" * 51, "bad name", "com.example.", "con.example", "under_score"):
            with self.assertRaises(windows_msix.PackageError):
                windows_msix.validate_name(name)
        self.assertEqual(windows_msix.validate_name("com.justspeaktoit.windows.developer"),
                         "com.justspeaktoit.windows.developer")

    def test_policy_changes_to_identity_are_refused(self):
        original = json.loads(windows_msix.IDENTITY_PATH.read_text(encoding="utf-8"))
        changes = [
            lambda data: data["fileSystem"].update(writeVirtualization="enabled"),
            lambda data: data["targetDeviceFamily"].update(minVersion="10.0.18362.0"),
            lambda data: data["presentation"].update(displayName="Just | Speak"),
            lambda data: data["capabilities"]["device"].append("webcam"),
            lambda data: data.update(releaseTrain="stable"),
            lambda data: data["identity"].update(processorArchitecture="arm64"),
            lambda data: data["application"].update(executionAlias="nested\\alias.exe"),
        ]
        with tempfile.TemporaryDirectory() as scratch:
            for change in changes:
                data = copy.deepcopy(original)
                change(data)
                path = pathlib.Path(scratch) / "identity.json"
                path.write_text(json.dumps(data), encoding="utf-8")
                with self.assertRaises(windows_msix.PackageError):
                    windows_msix.load_identity(path)


class ManifestTests(unittest.TestCase):
    def setUp(self):
        self.identity = windows_msix.load_identity()

    def test_manifest_declares_the_reviewed_identity_capabilities_and_unvirtualised_data(self):
        data = windows_msix.render_manifest(self.identity, "0.0.7.1", "CN=Just Speak to It Developer")
        root = ET.fromstring(data)
        ns = windows_msix.NAMESPACES
        self.assertEqual(root.find("f:Identity", ns).attrib, {
            "Name": "com.justspeaktoit.windows.developer", "Publisher": "CN=Just Speak to It Developer",
            "Version": "0.0.7.1", "ProcessorArchitecture": "x64"})
        self.assertEqual(root.findtext("f:Properties/desktop6:FileSystemWriteVirtualization", namespaces=ns),
                         "disabled")
        self.assertNotIn("desktop6", root.get("IgnorableNamespaces").split())
        application = root.find("f:Applications/f:Application", ns)
        self.assertEqual(application.get("Executable"), "SpeakWindows.exe")
        self.assertEqual(application.get("{%s}TrustLevel" % ns["uap10"]), "mediumIL")
        alias = application.find(".//desktop:ExecutionAlias", ns)
        self.assertEqual(alias.get("Alias"), "JustSpeakToItDeveloper.exe")
        names = [element.get("Name") for element in root.find("f:Capabilities", ns)]
        self.assertEqual(names, ["runFullTrust", "unvirtualizedResources", "microphone"])
        family = root.find("f:Dependencies/f:TargetDeviceFamily", ns)
        self.assertEqual((family.get("MinVersion"), family.get("MaxVersionTested")), ("10.0.19041.0", "10.0.20348.0"))

    def test_text_values_are_escaped(self):
        identity = copy.deepcopy(self.identity)
        identity["presentation"]["displayName"] = 'Speak <It> & "Quote"'
        data = windows_msix.render_manifest(identity, "1.0.0.0", "CN=Just Speak to It Developer")
        root = ET.fromstring(data)
        self.assertEqual(root.findtext("f:Properties/f:DisplayName", namespaces=windows_msix.NAMESPACES),
                         'Speak <It> & "Quote"')

    def test_manifest_that_differs_from_the_request_is_refused(self):
        data = windows_msix.render_manifest(self.identity, "0.0.7.1", "CN=Just Speak to It Developer")
        with self.assertRaises(windows_msix.PackageError):
            windows_msix.check_manifest(data, self.identity, "0.0.7.2", "CN=Just Speak to It Developer")
        weakened = data.replace(b">disabled</desktop6", b">enabled</desktop6")
        with self.assertRaises(windows_msix.PackageError):
            windows_msix.check_manifest(weakened, self.identity, "0.0.7.1", "CN=Just Speak to It Developer")
        ignorable = data.replace(b'IgnorableNamespaces="uap', b'IgnorableNamespaces="desktop6 uap')
        with self.assertRaises(windows_msix.PackageError):
            windows_msix.check_manifest(ignorable, self.identity, "0.0.7.1", "CN=Just Speak to It Developer")


class AssetTests(unittest.TestCase):
    def test_png_round_trip(self):
        pixels = bytes((x * 7 + y * 13 + channel * 31) & 255 for y in range(5) for x in range(9) for channel in range(4))
        self.assertEqual(windows_msix.decode_png(windows_msix.encode_png(9, 5, pixels)), (9, 5, pixels))

    def test_corrupt_png_is_refused(self):
        data = bytearray(windows_msix.encode_png(2, 2, bytes(16)))
        data[-20] ^= 1
        with self.assertRaises(windows_msix.PackageError):
            windows_msix.decode_png(bytes(data))

    def test_area_weights_cover_each_source_exactly_once(self):
        for source, target in ((256, 150), (256, 44), (256, 50), (7, 3), (3, 7)):
            weights = windows_msix._area_weights(source, target)
            self.assertTrue(all(sum(weight for _, weight in row) == source for row in weights))
            coverage = [0] * source
            for row in weights:
                for pixel, weight in row:
                    coverage[pixel] += weight
            self.assertEqual(coverage, [target] * source)

    def test_transparent_pixels_do_not_darken_edges(self):
        width = 8
        pixels = b"".join(bytes((0, 0, 0, 0)) if x < 4 else bytes((255, 107, 61, 255))
                          for y in range(width) for x in range(width))
        output = windows_msix.resample_rgba(width, width, pixels, 3, 3)
        for offset in range(0, len(output), 4):
            if output[offset + 3]:
                self.assertEqual(tuple(output[offset:offset + 3]), (255, 107, 61))
        solid = bytes((12, 34, 56, 255)) * 49
        self.assertEqual(windows_msix.resample_rgba(7, 7, solid, 3, 3), bytes((12, 34, 56, 255)) * 9)

    def test_logos_are_derived_from_the_canonical_icon_at_declared_sizes(self):
        identity = windows_msix.load_identity()
        assets, record = windows_msix.render_assets(identity)
        self.assertEqual(sorted(assets), sorted(identity["assets"]["images"]))
        source = (windows_msix.REPOSITORY / identity["assets"]["source"]).read_bytes()
        self.assertEqual(record["sourceSHA256"], sha256(source))
        for path, data in assets.items():
            size = identity["assets"]["images"][path]
            width, height, rgba = windows_msix.decode_png(data)
            self.assertEqual((width, height), (size, size))
            self.assertEqual(rgba[3], 0, "corners stay transparent")
            centre = ((size // 2) * size + size // 2) * 4
            self.assertEqual(rgba[centre + 3], 255, "artwork is opaque")
        again, _ = windows_msix.render_assets(identity)
        self.assertEqual(assets, again)


class LayoutTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.scratch.name)

    def tearDown(self):
        self.scratch.cleanup()

    def build(self, bundle=None, output="out", **options):
        bundle = bundle or make_bundle(self.root / "bundle")
        options.setdefault("version", "0.0.9.1")
        return windows_msix.build_layout(bundle, self.root / output, **options)

    def test_layout_is_the_verified_bundle_plus_generated_package_files(self):
        bundle = make_bundle(self.root / "bundle")
        evidence = self.build(bundle, expected_commit=COMMIT)
        layout = self.root / "out/layout"
        package_manifest, hashes = windows_msix.verify_layout(layout)
        with zipfile.ZipFile(next(bundle.glob("*.zip"))) as archive:
            for name in archive.namelist():
                self.assertEqual((layout / name).read_bytes(), archive.read(name), name)
                self.assertEqual(hashes[name], sha256(archive.read(name)))
        generated = {row["path"]: row["origin"] for row in package_manifest["files"] if row["origin"] != "bundle"}
        self.assertEqual(generated, {"AppxManifest.xml": "generated-manifest",
                                     "Assets/Square150x150Logo.png": "generated-asset",
                                     "Assets/Square44x44Logo.png": "generated-asset",
                                     "Assets/StoreLogo.png": "generated-asset"})
        self.assertEqual(package_manifest["package"]["packageFamilyName"],
                         "com.justspeaktoit.windows.developer_" + windows_msix.publisher_id(
                             "CN=Just Speak to It Developer"))
        self.assertFalse(package_manifest["package"]["signed"])
        self.assertEqual(package_manifest["bundle"]["sourceCommit"], COMMIT)
        self.assertEqual(package_manifest["bundle"]["runtimeModules"], ["swiftCore.dll"])
        self.assertEqual(package_manifest["executable"]["subsystem"], "console")
        self.assertEqual(evidence["layout"]["files"], len(hashes))

    def test_layout_is_deterministic(self):
        bundle = make_bundle(self.root / "bundle")
        self.build(bundle, output="first")
        self.build(bundle, output="second")
        first = {path.relative_to(self.root / "first").as_posix(): path.read_bytes()
                 for path in (self.root / "first").rglob("*") if path.is_file()}
        second = {path.relative_to(self.root / "second").as_posix(): path.read_bytes()
                  for path in (self.root / "second").rglob("*") if path.is_file()}
        self.assertEqual(first, second)

    def test_external_publisher_changes_the_package_family(self):
        publisher = "CN=Contoso Software, O=Contoso Corporation, C=US"
        evidence = self.build(publisher=publisher)
        self.assertEqual(evidence["package"]["publisher"], publisher)
        self.assertEqual(evidence["package"]["packageFamilyName"],
                         "com.justspeaktoit.windows.developer_" + windows_msix.publisher_id(publisher))
        manifest = ET.fromstring((self.root / "out/layout/AppxManifest.xml").read_bytes())
        self.assertEqual(manifest.find("f:Identity", windows_msix.NAMESPACES).get("Publisher"), publisher)

    def test_changed_or_foreign_bundles_are_refused(self):
        def tamper_archive(bundle):
            archive = next(bundle.glob("*.zip"))
            data = bytearray(archive.read_bytes())
            data[len(data) // 2] ^= 1
            archive.write_bytes(bytes(data))

        def rewrite_evidence(bundle, change):
            path = bundle / "bundle-evidence.json"
            evidence = json.loads(path.read_text(encoding="utf-8"))
            change(evidence)
            path.write_text(json.dumps(evidence), encoding="utf-8")

        cases = {
            "archive changed": ("does not match bundle-evidence", tamper_archive),
            "manifest hash": ("bundle-manifest.json does not match",
                              lambda bundle: rewrite_evidence(bundle, lambda e: e["manifest"].update(sha256="0" * 64))),
            "archive path": ("unexpected archive",
                             lambda bundle: rewrite_evidence(bundle, lambda e: e["zip"].update(name="../other.zip"))),
        }
        for label, (reason, change) in cases.items():
            with self.subTest(label):
                bundle = make_bundle(self.root / ("bundle-" + label.replace(" ", "-")))
                change(bundle)
                with self.assertRaisesRegex(windows_msix.PackageError, reason):
                    self.build(bundle, output="out-" + label.replace(" ", "-"))
        with self.assertRaisesRegex(windows_msix.PackageError, "source commit"):
            self.build(make_bundle(self.root / "other-commit"), output="wrong-commit", expected_commit="f" * 40)

    def test_bundle_contents_that_violate_policy_are_refused(self):
        def same_size_tamper(entries, manifest):
            # Recorded hashes come from the untampered bytes.
            manifest["application"]["executableSHA256"] = sha256(entries["SpeakWindows.exe"])

        production = "optimised production executable"
        mutations = {
            "test build": (production, lambda entries, manifest: manifest["application"].update(appBuiltForTesting=True)),
            "debug build": (production, lambda entries, manifest: manifest["application"].update(configuration="debug")),
            "other policy": ("different runtime policy",
                             lambda entries, manifest: manifest.update(policy=dict(manifest["policy"], testModules=[]))),
            "reserved manifest": ("reserved package paths",
                                  lambda entries, manifest: entries.update({"AppxManifest.xml": b"<Package/>"})),
            "reserved metadata": ("reserved package paths",
                                  lambda entries, manifest: entries.update({"AppxMetadata/CodeIntegrity.cat": b"x"})),
            "forbidden symbols": ("policy forbids", lambda entries, manifest: entries.update({"SpeakWindows.pdb": b"x"})),
            "percent name": ("cannot contain", lambda entries, manifest: entries.update({"licenses/100%.txt": b"x"})),
            "missing runtime": ("runtime module is missing", lambda entries, manifest: entries.pop("swiftCore.dll")),
        }
        for label, (reason, mutate) in mutations.items():
            with self.subTest(label):
                bundle = make_bundle(self.root / ("bundle-" + label.replace(" ", "-")), mutate=mutate)
                with self.assertRaisesRegex(windows_msix.PackageError, reason):
                    self.build(bundle, output="out-" + label.replace(" ", "-"))
        with self.assertRaisesRegex(windows_msix.PackageError, "test library XCTest.dll"):
            self.build(make_bundle(self.root / "xctest", exe_imports=("XCTest.dll",)), output="out-xctest")
        bundle = make_bundle(self.root / "bundle-extra")
        archive = next(bundle.glob("*.zip"))
        with zipfile.ZipFile(archive, "a") as handle:
            handle.writestr("extra.txt", b"not in the manifest")
        data = archive.read_bytes()
        evidence = json.loads((bundle / "bundle-evidence.json").read_text(encoding="utf-8"))
        evidence["zip"].update(sha256=sha256(data), bytes=len(data))
        (bundle / "bundle-evidence.json").write_text(json.dumps(evidence), encoding="utf-8")
        with self.assertRaisesRegex(windows_msix.PackageError, "does not list: extra.txt"):
            self.build(bundle, output="out-extra")

    def test_same_size_file_tamper_is_refused(self):
        bundle = make_bundle(self.root / "bundle")
        archive = next(bundle.glob("*.zip"))
        with zipfile.ZipFile(archive) as handle:
            entries = {name: handle.read(name) for name in handle.namelist()}
        notes = bytearray(entries["README.txt"])
        notes[0] ^= 1
        entries["README.txt"] = bytes(notes)
        BUILD.write_deterministic_zip(archive, entries)
        data = archive.read_bytes()
        evidence = json.loads((bundle / "bundle-evidence.json").read_text(encoding="utf-8"))
        evidence["zip"].update(sha256=sha256(data), bytes=len(data))
        (bundle / "bundle-evidence.json").write_text(json.dumps(evidence), encoding="utf-8")
        with self.assertRaisesRegex(windows_msix.PackageError, "README.txt"):
            self.build(bundle)

    def test_invalid_requests_and_unsafe_outputs_are_refused(self):
        bundle = make_bundle(self.root / "bundle")
        for options in ({"version": "1.2.3"}, {"publisher": "Contoso"}):
            with self.assertRaises(windows_msix.PackageError):
                self.build(bundle, output="bad", **options)
        with self.assertRaises(windows_msix.PackageError):
            windows_msix.build_layout(bundle, bundle / "inside", "0.0.1.0")
        (self.root / "occupied").mkdir()
        (self.root / "occupied/file").write_text("x", encoding="utf-8")
        with self.assertRaises(windows_msix.PackageError):
            self.build(bundle, output="occupied")

    def test_layout_changed_after_build_is_refused(self):
        self.build()
        layout = self.root / "out/layout"
        (layout / "README.txt").write_bytes(b"changed")
        with self.assertRaises(windows_msix.PackageError):
            windows_msix.verify_layout(layout)
        (layout / "README.txt").unlink()
        with self.assertRaises(windows_msix.PackageError):
            windows_msix.verify_layout(layout)


class PackageVerificationTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.scratch.name)
        windows_msix.build_layout(make_bundle(self.root / "bundle"), self.root / "out", "0.0.9.1")
        self.layout = self.root / "out/layout"

    def tearDown(self):
        self.scratch.cleanup()

    def test_unsigned_and_signed_packages_must_equal_the_layout(self):
        unsigned = make_package(self.layout, self.root / "unsigned.msix")
        result = windows_msix.verify_package(unsigned, self.layout, signed=False)
        self.assertEqual(result["payloadFiles"], len(windows_msix.verify_layout(self.layout)[1]))
        self.assertEqual(result["identity"]["version"], "0.0.9.1")
        signed = make_package(self.layout, self.root / "signed.msix", signed=True)
        windows_msix.verify_package(signed, self.layout, signed=True, unsigned_reference=unsigned)
        with self.assertRaises(windows_msix.PackageError):
            windows_msix.verify_package(unsigned, self.layout, signed=True)
        with self.assertRaises(windows_msix.PackageError):
            windows_msix.verify_package(signed, self.layout, signed=False)

    def test_payload_block_map_and_signing_differences_are_refused(self):
        unsigned = make_package(self.layout, self.root / "unsigned.msix")
        blockmap = build_blockmap({"README.txt": b"other"})
        cases = {
            "extra": ("unexpected \\['Injected.dll'\\]",
                      make_package(self.layout, self.root / "extra.msix", extra={"Injected.dll": b"MZ"})),
            "missing": ("missing \\['swiftCore.dll'\\]",
                        make_package(self.layout, self.root / "missing.msix", drop=["swiftCore.dll"])),
            "content": ("differs from the layout: README.txt", make_package(
                self.layout, self.root / "content.msix", replace={"README.txt": b"Developer bundlf\n"})),
            "blockmap": ("does not list exactly",
                         make_package(self.layout, self.root / "blockmap.msix", blockmap=blockmap)),
            "metadata": ("unexpected \\['AppxMetadata/CodeIntegrity.cat'\\]", make_package(
                self.layout, self.root / "metadata.msix", extra={"AppxMetadata/CodeIntegrity.cat": b"x"})),
        }
        for label, (reason, package) in cases.items():
            with self.subTest(label), self.assertRaisesRegex(windows_msix.PackageError, reason):
                windows_msix.verify_package(package, self.layout, signed=False)
        stale = build_blockmap({path.relative_to(self.layout).as_posix(): b"stale"
                                for path in self.layout.rglob("*") if path.is_file()})
        with self.assertRaisesRegex(windows_msix.PackageError, "block map hashes do not match"):
            windows_msix.verify_package(make_package(self.layout, self.root / "stale.msix", blockmap=stale),
                                        self.layout, signed=False)
        signed = make_package(self.layout, self.root / "signed.msix", signed=True)
        other = make_package(self.layout, self.root / "other-unsigned.msix",
                             blockmap=build_blockmap({"AppxManifest.xml": b"x"}))
        with self.assertRaisesRegex(windows_msix.PackageError, "signing changed the block map"):
            windows_msix.verify_package(signed, self.layout, signed=True, unsigned_reference=other)
        windows_msix.verify_package(signed, self.layout, signed=True, unsigned_reference=unsigned)

    def test_percent_encoded_part_names_are_decoded(self):
        package_manifest = json.loads((self.layout / windows_msix.PACKAGE_MANIFEST).read_text(encoding="utf-8"))
        data = b"spaced"
        (self.layout / "licenses/With Space.txt").write_bytes(data)
        package_manifest["files"].append({"path": "licenses/With Space.txt", "bytes": len(data),
                                          "sha256": sha256(data), "origin": "bundle"})
        (self.layout / windows_msix.PACKAGE_MANIFEST).write_text(json.dumps(package_manifest), encoding="utf-8")
        package = make_package(self.layout, self.root / "spaced.msix")
        with zipfile.ZipFile(package) as archive:
            self.assertIn("licenses/With%20Space.txt", archive.namelist())
        windows_msix.verify_package(package, self.layout, signed=False)


class LifecycleSupportTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.scratch.name)
        self.data = self.root / "JustSpeakToIt"
        self.expectations = lifecycle_support.write_fixture(self.data, self.root / "expectations.json")

    def tearDown(self):
        self.scratch.cleanup()

    def recover_like_the_app(self):
        # DesktopRecordingStore.recoverInterruptedRecordings and
        # PCMRecordingFile.recoverInterruptedFile, reproduced for the test.
        recovery = self.expectations["recovery"]
        record_path = self.data / recovery["record"]
        record = json.loads(record_path.read_text(encoding="utf-8"))
        record["failure"] = recovery["failure"]
        record["createdAt"] = int(record["createdAt"])
        record_path.write_text(json.dumps(record, indent=2, sort_keys=True), encoding="utf-8")
        audio_path = self.data / recovery["audio"]
        audio = bytearray(audio_path.read_bytes())
        payload = len(audio) - 44
        struct.pack_into("<I", audio, 4, payload + 36)
        struct.pack_into("<I", audio, 40, payload)
        audio_path.write_bytes(bytes(audio))

    def test_fixture_uses_the_apps_formats(self):
        completed = json.loads((self.data / ("History/%s.json" % lifecycle_support.COMPLETED_ID)).read_text(encoding="utf-8"))
        self.assertEqual(completed["result"]["text"], lifecycle_support.TRANSCRIPT)
        self.assertEqual(completed["id"], lifecycle_support.COMPLETED_ID)
        self.assertEqual(set(completed["result"]), {"duration", "modelIdentifier", "segments", "text"})
        interrupted = json.loads((self.data / ("History/%s.json" % lifecycle_support.INTERRUPTED_ID)).read_text(encoding="utf-8"))
        self.assertNotIn("result", interrupted)
        self.assertNotIn("failure", interrupted)
        self.assertGreater(completed["createdAt"], interrupted["createdAt"], "completed record is listed first")
        header = (self.data / ("History/%s.wav" % lifecycle_support.INTERRUPTED_ID)).read_bytes()[:44]
        expected = (b"RIFF" + struct.pack("<I", 36) + b"WAVEfmt " + struct.pack("<IHHIIHH", 16, 1, 1, 16000, 32000, 2, 16)
                    + b"data" + struct.pack("<I", 0))
        self.assertEqual(header, expected)
        audio = (self.data / ("History/%s.wav" % lifecycle_support.COMPLETED_ID)).read_bytes()
        self.assertEqual(audio[:44], lifecycle_support.wav_header(len(audio) - 44))
        self.assertTrue(any(audio[44:]), "fixture audio is not silent")
        self.assertEqual(json.loads((self.data / "settings.json").read_text(encoding="utf-8")), {"model": lifecycle_support.MODEL})
        with self.assertRaises(SystemExit):
            lifecycle_support.write_fixture(self.data, self.root / "again.json")

    def test_seeded_and_recovered_states_are_checked(self):
        self.assertEqual(lifecycle_support.check_data(self.data, self.expectations, "seeded")["failures"], [])
        self.assertTrue(lifecycle_support.check_data(self.data, self.expectations, "recovered")["failures"])
        self.recover_like_the_app()
        (self.data / "OpenRouterAudioCatalog.json").write_text("{}", encoding="utf-8")
        report = lifecycle_support.check_data(self.data, self.expectations, "recovered")
        self.assertEqual(report["failures"], [])
        self.assertEqual(report["appCreatedFiles"], ["OpenRouterAudioCatalog.json"])
        self.assertTrue(lifecycle_support.check_data(self.data, self.expectations, "seeded")["failures"])

    def test_lost_or_changed_user_data_is_reported(self):
        self.recover_like_the_app()
        cases = {
            "completed audio": lambda: (self.data / ("History/%s.wav" % lifecycle_support.COMPLETED_ID)).write_bytes(b"x"),
            "user note": lambda: (self.data / "keep-user-notes.txt").unlink(),
            "settings": lambda: (self.data / "settings.json").write_text('{"model": "other"}', encoding="utf-8"),
            "unexpected": lambda: (self.data / "History/stray.json").write_text("{}", encoding="utf-8"),
        }
        for label, change in cases.items():
            with self.subTest(label):
                snapshot = {path: path.read_bytes() for path in self.data.rglob("*") if path.is_file()}
                change()
                self.assertTrue(lifecycle_support.check_data(self.data, self.expectations, "recovered")["failures"])
                for path in list(self.data.rglob("*")):
                    if path.is_file() and path not in snapshot:
                        path.unlink()
                for path, data in snapshot.items():
                    path.write_bytes(data)
        audio_path = self.data / self.expectations["recovery"]["audio"]
        audio = bytearray(audio_path.read_bytes())
        audio[-1] ^= 1
        audio_path.write_bytes(bytes(audio))
        self.assertIn("recovered audio samples changed",
                      lifecycle_support.check_data(self.data, self.expectations, "recovered")["failures"])

    def test_tampering_changes_exactly_one_payload_byte(self):
        source = self.root / "package.msix"
        with zipfile.ZipFile(source, "w") as archive:
            archive.writestr("AppxManifest.xml", b"<Package/>")
            archive.writestr(zipfile.ZipInfo("Stored.bin"), bytes(range(256)) * 4)
            archive.writestr("Deflated.txt", b"deflated " * 100, compress_type=zipfile.ZIP_DEFLATED)
        output = self.root / "tampered.msix"
        result = lifecycle_support.tamper(source, output)
        self.assertEqual(result["entry"], "Stored.bin")
        self.assertTrue(result["stored"])
        original, changed = source.read_bytes(), output.read_bytes()
        self.assertEqual(len(original), len(changed))
        self.assertEqual(sum(1 for a, b in zip(original, changed) if a != b), 1)
        with zipfile.ZipFile(output) as archive:
            self.assertEqual(archive.read("Deflated.txt"), b"deflated " * 100)
            with self.assertRaises(zipfile.BadZipFile):
                archive.read("Stored.bin")


if __name__ == "__main__":
    unittest.main()
