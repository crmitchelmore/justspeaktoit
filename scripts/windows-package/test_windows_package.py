#!/usr/bin/env python3
"""Unit tests for the Windows developer MSIX layout and package verification; no downloads,
caches or Windows APIs.

Sibling test_windows_package_*.py files cover the manifest and assets, lifecycle
and signing. Other tooling tests load this module for COMMIT, write_bundle and
windows_msix.
"""
import json
import pathlib
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
import zipfile

HERE = pathlib.Path(__file__).resolve().parent
sys.dont_write_bytecode = True
sys.path.insert(0, str(HERE))
import windows_msix  # noqa: E402
from package_test_fixtures import (  # noqa: E402,F401
    BUILD,
    BUNDLE_TESTS,
    COMMIT,
    build_blockmap,
    make_bundle,
    make_package,
    sha256,
    write_bundle,
)


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
        expected = {path: "generated-asset" for path in windows_msix.load_identity()["assets"]["images"]}
        expected["AppxManifest.xml"] = "generated-manifest"
        self.assertEqual(generated, expected)
        self.assertEqual(package_manifest["package"]["packageFamilyName"],
                         "com.justspeaktoit.windows.developer_" + windows_msix.publisher_id(
                             "CN=Just Speak to It Developer"))
        self.assertFalse(package_manifest["package"]["signed"])
        self.assertEqual(package_manifest["bundle"]["sourceCommit"], COMMIT)
        self.assertEqual(package_manifest["bundle"]["runtimeModules"], ["swiftCore.dll"])
        self.assertEqual(package_manifest["executable"]["subsystem"], "windows")
        self.assertEqual(set(package_manifest["executables"]), set(BUILD.EXECUTABLES))
        self.assertEqual(package_manifest["executables"]["speak.exe"]["subsystem"], "console")
        self.assertEqual(package_manifest["package"]["cliExecutionAlias"], "JustSpeakToItDeveloperCLI.exe")
        self.assertEqual(package_manifest["package"]["cliApplicationId"], "JustSpeakToItCLI")
        self.assertEqual(package_manifest["package"]["cliAppUserModelId"],
                         package_manifest["package"]["packageFamilyName"] + "!JustSpeakToItCLI")
        self.assertEqual(evidence["layout"]["files"], len(hashes))

    def test_arm64_bundle_becomes_an_arm64_package_of_the_same_identity(self):
        bundle = make_bundle(self.root / "bundle", architecture="arm64")
        evidence = self.build(bundle, expected_commit=COMMIT)
        self.assertEqual(evidence["package"]["architecture"], "arm64")
        self.assertIn("_0.0.9.1_arm64__", evidence["package"]["packageFullName"])
        package_manifest, _ = windows_msix.verify_layout(self.root / "out/layout")
        self.assertEqual(package_manifest["package"]["kind"], "unsigned Windows ARM64 developer MSIX payload")
        manifest = ET.fromstring((self.root / "out/layout/AppxManifest.xml").read_bytes())
        self.assertEqual(manifest.find("f:Identity", windows_msix.NAMESPACES).get("ProcessorArchitecture"), "arm64")
        self.assertEqual(package_manifest["package"]["cliApplicationId"], "JustSpeakToItCLI")
        self.assertEqual(package_manifest["package"]["cliAppUserModelId"],
                         package_manifest["package"]["packageFamilyName"] + "!JustSpeakToItCLI")
        x64 = self.build(make_bundle(self.root / "x64-bundle"), output="x64")
        self.assertEqual(x64["package"]["packageFamilyName"], evidence["package"]["packageFamilyName"])
        self.assertEqual(x64["package"]["architecture"], "x64")

    def test_images_foreign_to_the_bundle_architecture_are_refused(self):
        arm64 = windows_msix.windows_pe.IMAGE_FILE_MACHINE_ARM64
        cases = [
            ("x64-dll", "arm64", lambda entries, manifest: entries.update(
                {"swiftCore.dll": BUNDLE_TESTS.build_pe(imports=["KERNEL32.dll"], dll=True)}),
             "swiftCore.dll is not a native arm64 DLL"),
            ("arm64ec-dll", "arm64", lambda entries, manifest: entries.update(
                {"swiftCore.dll": BUNDLE_TESTS.build_pe(imports=["KERNEL32.dll"], dll=True, hybrid_metadata=0x18000A2E8)}),
             "not a native arm64 DLL \\(it is arm64ec\\)"),
            ("arm64-exe-in-x64", "x64", lambda entries, manifest: entries.update(
                {"SpeakWindows.exe": BUNDLE_TESTS.build_pe(imports=["KERNEL32.dll"], machine=arm64)}) or
             manifest["application"].update(executableSHA256=sha256(entries["SpeakWindows.exe"])) or
             manifest["application"]["executables"].update({"SpeakWindows.exe": sha256(entries["SpeakWindows.exe"])}),
             "not a Windows x64 executable \\(it is arm64\\)"),
            ("no-architecture", "x64", lambda entries, manifest: manifest["bundle"].pop("architecture"),
             "unsupported bundle architecture"),
        ]
        for name, architecture, mutate, message in cases:
            bundle = make_bundle(self.root / name, mutate=mutate, architecture=architecture)
            if name == "arm64-exe-in-x64":
                # The evidence names the recorded executable; keep it consistent with the mutation.
                evidence = json.loads((bundle / "bundle-evidence.json").read_text(encoding="utf-8"))
                with zipfile.ZipFile(next(bundle.glob("*.zip"))) as archive:
                    evidence["application"]["executableSHA256"] = sha256(archive.read("SpeakWindows.exe"))
                (bundle / "bundle-evidence.json").write_text(json.dumps(evidence), encoding="utf-8")
            with self.assertRaisesRegex(windows_msix.PackageError, message, msg=name):
                self.build(bundle, output="out-" + name)

    def test_layout_is_deterministic(self):
        bundle = make_bundle(self.root / "bundle")
        self.build(bundle, output="first")
        self.build(bundle, output="second")
        first = {path.relative_to(self.root / "first").as_posix(): path.read_bytes()
                 for path in (self.root / "first").rglob("*") if path.is_file()}
        second = {path.relative_to(self.root / "second").as_posix(): path.read_bytes()
                  for path in (self.root / "second").rglob("*") if path.is_file()}
        self.assertEqual(first, second)

    def test_missing_tampered_retargeted_cli_and_false_root_attribution_are_refused(self):
        def replace_cli(entries, manifest, data):
            entries["speak.exe"] = data
            manifest["application"]["executables"]["speak.exe"] = sha256(data)

        cases = [
            ("missing", lambda entries, manifest: entries.pop("speak.exe"), "production executable"),
            ("tampered", lambda entries, manifest: entries.update({"speak.exe": entries["speak.exe"] + b"tamper"}),
             "production executable"),
            ("no-cli-receipt", lambda entries, manifest: manifest["application"]["executables"].pop("speak.exe"),
             "production executable"),
            ("foreign-cli", lambda entries, manifest: replace_cli(entries, manifest, BUNDLE_TESTS.build_pe(
                machine=windows_msix.windows_pe.IMAGE_FILE_MACHINE_ARM64)), "speak.exe is not a Windows x64"),
            ("cli-test", lambda entries, manifest: replace_cli(entries, manifest, BUNDLE_TESTS.build_pe(
                delay_imports=["Testing.dll"])), "speak.exe imports the test library Testing.dll"),
            ("gui-as-cli", lambda entries, manifest: replace_cli(entries, manifest, entries["SpeakWindows.exe"]),
             "console subsystem"),
            ("cli-unknown", lambda entries, manifest: replace_cli(entries, manifest, BUNDLE_TESTS.build_pe(
                imports=["unreviewed.dll"])), "speak.exe imports unreviewed.dll"),
            ("false-importer", lambda entries, manifest: manifest["dependencies"]["bundled"]["swiftcore.dll"]
             ["importedBy"].pop(), "importer attribution"),
            ("false-root", lambda entries, manifest: manifest["dependencies"]["roots"]["speak.exe"].update(
                staticModules=[]), "multi-root dependency closure"),
            ("cli-source", lambda entries, manifest: manifest["application"].update(buildHost="unreviewed"),
             "source provenance"),
            ("cli-target", lambda entries, manifest: manifest["application"].update(target="x86_64-unknown-linux-gnu"),
             "source provenance"),
            ("extra-executable", lambda entries, manifest: entries.update({"other.exe": entries["speak.exe"]}),
             "exact production multi-root closure"),
        ]
        for name, mutate, reason in cases:
            with self.subTest(name=name):
                bundle = make_bundle(self.root / name, mutate=mutate)
                with self.assertRaisesRegex(windows_msix.PackageError, reason):
                    self.build(bundle, output="out-" + name)
                self.assertFalse((self.root / ("out-" + name)).exists())

    def test_producer_multi_root_graph_round_trips_with_resources_and_miniz_licence(self):
        for architecture in ("x64", "arm64"):
            with self.subTest(architecture=architecture):
                fixture = BUNDLE_TESTS.AssemblyTests()
                fixture.setUp(architecture)
                try:
                    cli = BUNDLE_TESTS.build_pe(imports=["swiftWinSDK.dll"], delay_imports=["Foundation.dll"],
                                               machine=windows_msix.windows_targets.target(architecture)["processMachine"])
                    fixture.application["executables"]["speak.exe"] = cli
                    fixture.application["metadata"]["executables"]["speak.exe"] = sha256(cli)
                    fixture.application["resources"]["SpeakApp_Future.resources/nested/payload.json"] = b"{}"
                    licence = BUNDLE_TESTS.MIGRATION.license_entry(windows_msix.REPOSITORY)
                    entries, manifest = fixture.assemble(architecture=architecture, licenses=fixture.licenses + [licence])
                    bundle = write_bundle(self.root / ("producer-" + architecture), entries, manifest, architecture)
                    result = windows_msix.verify_bundle(bundle, fixture.application["metadata"]["sourceCommit"])
                    self.assertEqual(result["manifest"]["dependencies"], manifest["dependencies"])
                    self.assertNotIn("swiftWinSDK.dll", manifest["dependencies"]["roots"]["SpeakWindows.exe"]["staticModules"])
                    self.build(bundle, output="producer-out-" + architecture)
                    layout = self.root / ("producer-out-" + architecture) / "layout"
                    self.assertEqual((layout / "speak.exe").read_bytes(), cli)
                    self.assertEqual((layout / "SpeakApp_Future.resources/nested/payload.json").read_bytes(), b"{}")
                    self.assertEqual((layout / "licenses/LICENSE-miniz.txt").read_bytes(), licence["data"])
                finally:
                    fixture.doCleanups()

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

    def test_signing_may_add_only_its_code_integrity_catalogue(self):
        catalogue = {windows_msix.CODE_INTEGRITY_PART: b"0\x82catalogue"}
        unsigned = make_package(self.layout, self.root / "unsigned.msix")
        listed = make_package(self.layout, self.root / "listed.msix", signed=True, listed_extra=catalogue)
        result = windows_msix.verify_package(listed, self.layout, signed=True, unsigned_reference=unsigned)
        self.assertEqual(result["payloadFiles"], len(windows_msix.verify_layout(self.layout)[1]))
        unlisted = make_package(self.layout, self.root / "unlisted.msix", signed=True, extra=catalogue)
        windows_msix.verify_package(unlisted, self.layout, signed=True, unsigned_reference=unsigned)
        with self.assertRaisesRegex(windows_msix.PackageError, "unexpected \\['AppxMetadata/CodeIntegrity.cat'\\]"):
            windows_msix.verify_package(make_package(self.layout, self.root / "unsigned-catalogue.msix",
                                                     listed_extra=catalogue), self.layout, signed=False)
        files = {path.relative_to(self.layout).as_posix(): path.read_bytes()
                 for path in self.layout.rglob("*") if path.is_file()}
        stale = build_blockmap(dict(files, **{windows_msix.CODE_INTEGRITY_PART: b"other"}))
        tampered = make_package(self.layout, self.root / "stale-catalogue.msix", signed=True, extra=catalogue,
                                blockmap=stale)
        with self.assertRaisesRegex(windows_msix.PackageError, "block map hashes do not match AppxMetadata"):
            windows_msix.verify_package(tampered, self.layout, signed=True)
        changed = dict(files, **catalogue)
        changed["README.txt"] = b"changed while signing"
        rewritten = make_package(self.layout, self.root / "rewritten.msix", signed=True, extra=catalogue,
                                 blockmap=build_blockmap(changed))
        with self.assertRaises(windows_msix.PackageError):
            windows_msix.verify_package(rewritten, self.layout, signed=True, unsigned_reference=unsigned)
        other = make_package(self.layout, self.root / "other.msix", blockmap=build_blockmap({"AppxManifest.xml": b"x"}))
        with self.assertRaisesRegex(windows_msix.PackageError, "signing changed the block map"):
            windows_msix.verify_package(listed, self.layout, signed=True, unsigned_reference=other)

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


if __name__ == "__main__":
    unittest.main()
