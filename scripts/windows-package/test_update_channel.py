#!/usr/bin/env python3
"""Multi-architecture bundle, App Installer and winget template tests; synthetic packages only."""
import importlib.util
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
import update_channel  # noqa: E402
import windows_msix  # noqa: E402

SPEC = importlib.util.spec_from_file_location("windows_package_tests", HERE / "test_windows_package.py")
PACKAGE_TESTS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PACKAGE_TESTS)
DEVELOPER = "CN=Just Speak to It Developer"
PUBLISHER = 'CN="Open Source Developer, Example Person", O=Open Source Developer, L=Leeds, C=GB'


def make_msixbundle(path, packages, version, publisher=DEVELOPER, signed=False, name=None, extra=None,
                    manifest_edit=None):
    """An .msixbundle shaped as MakeAppx bundle writes it."""
    ns = windows_msix.BUNDLE_NAMESPACE
    root = ET.Element("{%s}Bundle" % ns, SchemaVersion="5.0")
    ET.SubElement(root, "{%s}Identity" % ns, Name=name or "com.justspeaktoit.windows.developer",
                  Publisher=publisher, Version=version)
    listed = ET.SubElement(root, "{%s}Packages" % ns)
    for package in packages:
        identity = windows_msix.read_package_identity(package)
        ET.SubElement(listed, "{%s}Package" % ns, Type="application", Version=identity["Version"],
                      Architecture=identity["ProcessorArchitecture"], FileName=pathlib.Path(package).name,
                      Offset="0", Size=str(pathlib.Path(package).stat().st_size))
    manifest = ET.tostring(root, xml_declaration=True, encoding="utf-8")
    if manifest_edit:
        manifest = manifest_edit(manifest)
    with zipfile.ZipFile(path, "w") as archive:
        for package in packages:
            archive.write(package, pathlib.Path(package).name, compress_type=zipfile.ZIP_STORED)
        archive.writestr(windows_msix.BUNDLE_MANIFEST_PART, manifest)
        archive.writestr("AppxBlockMap.xml", b"<BlockMap/>")
        archive.writestr("[Content_Types].xml", b"<Types/>")
        for part, data in (extra or {}).items():
            archive.writestr(part, data)
        if signed:
            archive.writestr("AppxSignature.p7x", b"PKCX synthetic bundle signature")
    return path


class BundleTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.root = pathlib.Path(self.scratch.name)

    def package(self, architecture, version="0.0.9.4", publisher=None):
        bundle = PACKAGE_TESTS.make_bundle(self.root / ("bundle-" + architecture + version), architecture=architecture,
                                           cli=True)
        output = self.root / ("layout-" + architecture + version)
        windows_msix.build_layout(bundle, output, version, publisher=publisher)
        return PACKAGE_TESTS.make_package(output / "layout", self.root / (
            "JustSpeakToIt-Developer_%s_%s.msix" % (version, architecture)))

    def test_both_architectures_share_one_bundle_identity(self):
        packages = [self.package("x64"), self.package("arm64")]
        bundle = make_msixbundle(self.root / "JustSpeakToIt-Developer_0.0.9.4.msixbundle", packages, "0.0.9.4")
        evidence = windows_msix.verify_msixbundle(bundle, packages, signed=False)
        self.assertEqual([package["architecture"] for package in evidence["packages"]], ["arm64", "x64"])
        self.assertEqual(evidence["identity"]["packageFamilyName"],
                         "com.justspeaktoit.windows.developer_" + windows_msix.publisher_id(DEVELOPER))
        signed = make_msixbundle(self.root / "signed.msixbundle", packages, "0.0.9.4", signed=True,
                                 extra={"AppxMetadata/CodeIntegrity.cat": b"catalogue"})
        self.assertTrue(windows_msix.verify_msixbundle(signed, packages, signed=True)["signed"])
        with self.assertRaisesRegex(windows_msix.PackageError, "signed but unsigned"):
            windows_msix.verify_msixbundle(signed, packages, signed=False)

    def test_mismatched_or_changed_bundles_are_refused(self):
        x64, arm64 = self.package("x64"), self.package("arm64")
        cases = {
            "differs from its input": lambda: make_msixbundle(self.root / "a.msixbundle", [x64, arm64], "0.0.9.4"),
            "identity differs": lambda: make_msixbundle(self.root / "b.msixbundle", [x64, arm64], "0.0.9.5"),
            "unexpected": lambda: make_msixbundle(self.root / "c.msixbundle", [x64, arm64], "0.0.9.4",
                                                  extra={"notes.txt": b"x"}),
            "misdescribes": lambda: make_msixbundle(
                self.root / "d.msixbundle", [x64, arm64], "0.0.9.4",
                manifest_edit=lambda data: data.replace(b'Architecture="arm64"', b'Architecture="x86"')),
        }
        for message, build in cases.items():
            with self.subTest(message=message):
                bundle = build()
                inputs = [x64, arm64]
                if message == "differs from its input":
                    tampered = self.root / "tampered" / x64.name
                    tampered.parent.mkdir(exist_ok=True)
                    tampered.write_bytes(x64.read_bytes() + b"\0")
                    inputs = [tampered, arm64]
                    with self.assertRaisesRegex(windows_msix.PackageError, "differs from its input"):
                        windows_msix.verify_msixbundle(bundle, inputs, signed=False)
                    continue
                with self.assertRaisesRegex(windows_msix.PackageError, message):
                    windows_msix.verify_msixbundle(bundle, inputs, signed=False)
        with self.assertRaisesRegex(windows_msix.PackageError, "share the x64"):
            windows_msix.verify_msixbundle(self.root / "a.msixbundle", [x64, x64], signed=False)
        other = self.package("arm64", version="0.0.9.5")
        with self.assertRaisesRegex(windows_msix.PackageError, "one name, publisher and version"):
            windows_msix.verify_msixbundle(self.root / "a.msixbundle", [x64, other], signed=False)


class UpdateChannelTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.root = pathlib.Path(self.scratch.name)
        self.channels = update_channel.load_channels()

    def bundle(self, name="com.justspeaktoit.windows.developer", publisher=DEVELOPER, signed=False):
        work = pathlib.Path(tempfile.mkdtemp(dir=self.root))
        packages = []
        for architecture in ("x64", "arm64"):
            source = PACKAGE_TESTS.make_bundle(work / ("rt-" + architecture), architecture=architecture)
            identity = windows_msix.load_identity()
            identity["identity"]["name"] = name
            output = work / ("layout-" + architecture)
            windows_msix.build_layout(source, output, "1.2.3.0", publisher=publisher, identity=identity)
            packages.append(PACKAGE_TESTS.make_package(output / "layout", work / (
                "%s_1.2.3.0_%s.msix" % (name, architecture))))
        return make_msixbundle(work / ("JustSpeakToIt_1.2.3.0-%s.msixbundle" % name), packages, "1.2.3.0",
                               publisher=publisher, signed=signed, name=name)

    def test_channels_reserve_train_identities_without_commissioning_them(self):
        trains = json.loads((windows_msix.REPOSITORY / "Sources/SpeakCore/Resources/ReleaseTrains.json").read_text(
            encoding="utf-8"))
        channels = self.channels["channels"]
        self.assertTrue(channels["developer"]["commissioned"])
        self.assertFalse(channels["alpha"]["commissioned"])
        self.assertFalse(channels["stable"]["commissioned"])
        self.assertEqual({channels[name]["releaseTrain"] for name in ("alpha", "stable")}, {"alpha", "stable"})
        self.assertTrue(set(trains) >= {"alpha", "stable"})
        self.assertEqual(len({channel["packageName"] for channel in channels.values()}), 3)
        self.assertEqual(channels["stable"]["appInstallerLocation"], "github-latest")
        self.assertNotEqual(channels["alpha"]["appInstallerLocation"], "github-latest")

    def test_the_developer_bundle_gets_an_app_installer_file_that_updates_from_the_feed(self):
        bundle = self.bundle()
        record = update_channel.generate(bundle, "developer", "windows-developer-1.2.3.0", self.root / "out",
                                         environment={}, channels=self.channels)
        self.assertFalse(record["published"])
        base = "https://github.com/crmitchelmore/justspeaktoit/releases/download/windows-developer-1.2.3.0/"
        self.assertEqual(record["packageUri"], base + bundle.name)
        self.assertEqual(record["appInstallerUri"], base + "JustSpeakToIt-Developer.appinstaller")
        root = ET.parse(self.root / "out" / "JustSpeakToIt-Developer.appinstaller").getroot()
        ns = {"a": update_channel.APPINSTALLER_NAMESPACE}
        self.assertEqual(root.get("Uri"), record["appInstallerUri"])
        main = root.find("a:MainBundle", ns)
        self.assertEqual((main.get("Name"), main.get("Publisher"), main.get("Version")),
                         ("com.justspeaktoit.windows.developer", DEVELOPER, "1.2.3.0"))
        on_launch = root.find("a:UpdateSettings/a:OnLaunch", ns)
        self.assertEqual((on_launch.get("HoursBetweenUpdateChecks"), on_launch.get("UpdateBlocksActivation")),
                         ("12", "false"))
        self.assertIsNotNone(root.find("a:UpdateSettings/a:AutomaticBackgroundTask", ns))
        self.assertEqual(record["files"], ["JustSpeakToIt-Developer.appinstaller"], "no winget for developer builds")

    def test_a_preview_names_the_file_the_signed_build_will_have(self):
        bundle = self.bundle()
        record = update_channel.generate(bundle, "developer", "t", self.root / "preview", environment={},
                                         channels=self.channels, published_name="JustSpeakToIt-Developer_1.2.3.0.msixbundle")
        self.assertTrue(record["packageUri"].endswith("/download/t/JustSpeakToIt-Developer_1.2.3.0.msixbundle"))
        with self.assertRaises(update_channel.UpdateChannelError):
            update_channel.generate(bundle, "developer", "t", self.root / "preview-2", environment={},
                                    channels=self.channels, published_name="../evil.msixbundle")

    def test_the_feed_base_comes_from_a_variable(self):
        bundle = self.bundle()
        record = update_channel.generate(bundle, "developer", "t1", self.root / "fork",
                                         environment={"WINDOWS_UPDATE_FEED_BASE": "https://github.com/fork/jsti/releases/"},
                                         channels=self.channels)
        self.assertTrue(record["packageUri"].startswith("https://github.com/fork/jsti/releases/download/t1/"))
        for bad in ("http://example.com/releases", "https://example.com/releases?x=1", "ftp://x"):
            with self.assertRaises(update_channel.UpdateChannelError):
                update_channel.feed_base(self.channels, bad, {})

    def test_stable_uses_github_latest_and_gets_a_winget_template(self):
        bundle = self.bundle(name="com.justspeaktoit.windows", publisher=PUBLISHER, signed=True)
        record = update_channel.generate(bundle, "stable", "windows-v1.2.3.0", self.root / "stable", environment={},
                                         channels=self.channels)
        self.assertEqual(record["appInstallerUri"],
                         "https://github.com/crmitchelmore/justspeaktoit/releases/latest/download/JustSpeakToIt.appinstaller")
        self.assertFalse(record["commissioned"])
        folder = self.root / "stable/winget/manifests/c/crmitchelmore/JustSpeakToIt/1.2.3.0"
        installer = (folder / "crmitchelmore.JustSpeakToIt.installer.yaml").read_text(encoding="utf-8")
        self.assertIn("InstallerType: msix", installer)
        self.assertIn("- Architecture: arm64", installer)
        self.assertIn("- Architecture: x64", installer)
        self.assertIn("InstallerSha256: " + record["package"]["sha256"], installer)
        self.assertIn("SignatureSha256: " + record["package"]["signatureSha256"], installer)
        self.assertIn("PackageFamilyName: com.justspeaktoit.windows_" + windows_msix.publisher_id(PUBLISHER), installer)
        self.assertIn("MinimumOSVersion: 10.0.19041.0", installer)
        self.assertIn("winget-manifest.installer.1.10.0.schema.json", installer)
        locale = (folder / "crmitchelmore.JustSpeakToIt.locale.en-GB.yaml").read_text(encoding="utf-8")
        self.assertIn("License: MIT", locale)
        version = (folder / "crmitchelmore.JustSpeakToIt.yaml").read_text(encoding="utf-8")
        self.assertIn("ManifestType: version", version)
        unsigned = self.bundle(name="com.justspeaktoit.windows", publisher=PUBLISHER)
        other = update_channel.generate(unsigned, "stable", "windows-v1.2.3.0", self.root / "stable-unsigned",
                                        environment={}, channels=self.channels)
        text = (self.root / "stable-unsigned" / other["files"][2]).read_text(encoding="utf-8")
        self.assertNotIn("SignatureSha256", text)

    def test_alpha_needs_its_own_app_installer_url(self):
        bundle = self.bundle(name="com.justspeaktoit.windows.alpha")
        with self.assertRaisesRegex(update_channel.UpdateChannelError, "WINDOWS_ALPHA_APPINSTALLER_URL"):
            update_channel.generate(bundle, "alpha", "alpha-build-7", self.root / "alpha", environment={},
                                    channels=self.channels)
        record = update_channel.generate(bundle, "alpha", "alpha-build-7", self.root / "alpha2", environment={},
                                         appinstaller_uri="https://justspeaktoit.com/alpha/windows/JustSpeakToIt-Alpha.appinstaller",
                                         channels=self.channels)
        self.assertEqual(record["files"], ["JustSpeakToIt-Alpha.appinstaller"])

    def test_a_package_of_another_channel_or_an_unsafe_tag_is_refused(self):
        bundle = self.bundle()
        with self.assertRaisesRegex(update_channel.UpdateChannelError, "not the stable channel"):
            update_channel.generate(bundle, "stable", "windows-v1", self.root / "x", environment={}, channels=self.channels)
        for tag in ("", "../x", "a b", "-lead"):
            with self.assertRaises(update_channel.UpdateChannelError):
                update_channel.generate(bundle, "developer", tag, self.root / ("t" + str(len(tag))), environment={},
                                        channels=self.channels)
        (self.root / "busy").mkdir()
        (self.root / "busy" / "old").write_text("x", encoding="utf-8")
        with self.assertRaisesRegex(update_channel.UpdateChannelError, "new or empty"):
            update_channel.generate(bundle, "developer", "t", self.root / "busy", environment={}, channels=self.channels)

    def test_a_single_package_uses_main_package_with_its_architecture(self):
        source = PACKAGE_TESTS.make_bundle(self.root / "single-rt")
        windows_msix.build_layout(source, self.root / "single", "1.0.0.0")
        package = PACKAGE_TESTS.make_package(self.root / "single" / "layout", self.root / "single.msix")
        record = update_channel.generate(package, "developer", "t", self.root / "single-out", environment={},
                                         channels=self.channels)
        root = ET.parse(self.root / "single-out" / record["files"][0]).getroot()
        main = root.find("{%s}MainPackage" % update_channel.APPINSTALLER_NAMESPACE)
        self.assertEqual(main.get("ProcessorArchitecture"), "x64")


if __name__ == "__main__":
    unittest.main()
