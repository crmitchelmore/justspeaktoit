#!/usr/bin/env python3
"""Unit tests for the Windows beta and Store installer helpers; no downloads, caches or Windows APIs."""
import hashlib
import io
import pathlib
import sys
import tempfile
import unittest
import zipfile

HERE = pathlib.Path(__file__).resolve().parent
sys.dont_write_bytecode = True
sys.path.insert(0, str(HERE))
import windows_installer  # noqa: E402
import windows_msix  # noqa: E402

PUBLISHER = "CN=Example Ltd, O=Example Ltd, L=London, C=GB"
VERSION = "2026.1030.1641.0"
BUNDLE_URI = ("https://github.com/crmitchelmore/justspeaktoit/releases/download/alpha-build-44/"
              "JustSpeakToIt-windows_2026.1030.1641.0.msixbundle")
NAME = "com.justspeaktoit.windows"


class BetaIdentityTests(unittest.TestCase):
    def setUp(self):
        self.beta = windows_msix.load_identity(windows_msix.BETA_IDENTITY_PATH)
        self.developer = windows_msix.load_identity()

    def test_beta_is_a_separate_family_with_its_own_aliases_and_no_default_publisher(self):
        self.assertEqual(self.beta["channel"], "beta")
        self.assertEqual(self.beta["identity"]["name"], NAME)
        self.assertNotIn("developerPublisher", self.beta["identity"])
        self.assertEqual(sorted(self.beta["identity"]["processorArchitectures"]), ["arm64", "x64"])
        for key in ("executionAlias",):
            self.assertNotEqual(self.beta["application"][key], self.developer["application"][key])
        self.assertNotEqual(self.beta["cli"]["executionAlias"], self.developer["cli"]["executionAlias"])
        self.assertNotEqual(self.beta["identity"]["name"], self.developer["identity"]["name"])
        self.assertIn("Beta", self.beta["presentation"]["displayName"])
        # Both channels share one data directory, so moving to the beta keeps History and settings.
        self.assertEqual(self.beta["fileSystem"], self.developer["fileSystem"])

    def test_beta_layout_needs_the_signing_subject(self):
        with tempfile.TemporaryDirectory() as scratch:
            with self.assertRaises(windows_msix.PackageError):
                windows_msix.build_layout(pathlib.Path(scratch), pathlib.Path(scratch) / "out", VERSION,
                                          identity=self.beta)

    def test_beta_manifest_names_the_beta_aliases(self):
        for architecture in ("x64", "arm64"):
            text = windows_msix.render_manifest(self.beta, VERSION, PUBLISHER, architecture=architecture)
            self.assertIn(b'Name="%s"' % NAME.encode(), text)
            self.assertIn(b'ProcessorArchitecture="%s"' % architecture.encode(), text)
            self.assertIn(self.beta["cli"]["executionAlias"].encode(), text)
            self.assertNotIn(self.developer["cli"]["executionAlias"].encode(), text)

    def test_a_beta_identity_with_a_developer_publisher_is_refused(self):
        import json
        data = json.loads(windows_msix.BETA_IDENTITY_PATH.read_text(encoding="utf-8"))
        data["identity"]["developerPublisher"] = "CN=Just Speak to It Developer"
        with tempfile.TemporaryDirectory() as scratch:
            path = pathlib.Path(scratch) / "identity.json"
            path.write_text(json.dumps(data), encoding="utf-8")
            with self.assertRaises(windows_msix.PackageError):
                windows_msix.load_identity(path)

    def test_native_cli_alias_lookup_names_every_channel_family(self):
        native = (windows_msix.REPOSITORY / "Sources/CWindowsSupport/WindowsAutomationSettings.cpp").read_text(
            encoding="utf-8")
        store = windows_msix.load_identity(windows_msix.STORE_IDENTITY_PATH)
        for channel in (self.beta, self.developer, store):
            self.assertIn('L"%s_"' % channel["identity"]["name"], native)
            self.assertIn('L"%s"' % channel["cli"]["executionAlias"], native)


class StoreIdentityTests(unittest.TestCase):
    def setUp(self):
        self.store = windows_msix.load_identity(windows_msix.STORE_IDENTITY_PATH)
        self.raw = windows_msix.STORE_IDENTITY_PATH.read_text(encoding="utf-8")

    def test_store_identity_is_the_partner_center_reservation(self):
        publisher = windows_msix.fixed_publisher(self.store)
        self.assertEqual(publisher, "CN=4F44EE59-E9FC-48C5-A032-B34982E6C0CB")
        identity = windows_msix.package_identity(self.store, VERSION, publisher, "x64")
        self.assertEqual(identity["packageFamilyName"], "ChrisMitchelmore.JustSpeaktoIt_wqe2sjac9b4k8")
        text = windows_msix.render_manifest(self.store, VERSION, publisher, architecture="arm64")
        self.assertIn(b'Name="ChrisMitchelmore.JustSpeaktoIt"', text)
        self.assertIn(b'Publisher="CN=4F44EE59-E9FC-48C5-A032-B34982E6C0CB"', text)
        self.assertIn(b"<PublisherDisplayName>Chris Mitchelmore</PublisherDisplayName>", text)

    def test_store_layout_refuses_another_publisher(self):
        with tempfile.TemporaryDirectory() as scratch:
            with self.assertRaisesRegex(windows_msix.PackageError, "Partner Center publisher"):
                windows_msix.build_layout(pathlib.Path(scratch), pathlib.Path(scratch) / "out", VERSION,
                                          publisher=PUBLISHER, identity=self.store)

    def test_a_store_identity_that_drifts_from_the_reservation_is_refused(self):
        import json
        for path, value in ((("identity", "publisher"), "CN=Example Ltd"),
                            (("identity", "packageFamilyName"), "ChrisMitchelmore.JustSpeaktoIt_0000000000000"),
                            (("presentation", "publisherDisplayName"), "Example Ltd"),
                            (("identity", "developerPublisher"), "CN=Just Speak to It Developer")):
            data = json.loads(self.raw)
            data[path[0]][path[1]] = value
            with tempfile.TemporaryDirectory() as scratch:
                target = pathlib.Path(scratch) / "identity.json"
                target.write_text(json.dumps(data), encoding="utf-8")
                with self.assertRaises(windows_msix.PackageError, msg=path):
                    windows_msix.load_identity(target)

    def test_only_the_store_channel_states_a_store_publisher(self):
        import json
        data = json.loads(windows_msix.BETA_IDENTITY_PATH.read_text(encoding="utf-8"))
        data["identity"]["publisher"] = self.store["identity"]["publisher"]
        with tempfile.TemporaryDirectory() as scratch:
            target = pathlib.Path(scratch) / "identity.json"
            target.write_text(json.dumps(data), encoding="utf-8")
            with self.assertRaises(windows_msix.PackageError):
                windows_msix.load_identity(target)


class VersionTests(unittest.TestCase):
    def test_builds_map_to_strictly_increasing_package_versions(self):
        self.assertEqual(windows_installer.package_version("202610301641"), VERSION)
        self.assertEqual(windows_installer.package_version("000000000000"), "0.0.0.0")
        self.assertEqual(windows_installer.package_version("999999999999"), "9999.9999.9999.0")
        builds = ["202610301641", "202610301642", "202610301700", "202610311641", "202611010000", "202701010000"]
        versions = [tuple(map(int, windows_installer.package_version(build).split("."))) for build in builds]
        self.assertEqual(versions, sorted(versions))
        self.assertEqual(len(set(versions)), len(versions))
        for bad in ("20261030164", "2026103016411", "2026-10-30-16", 202610301641, None):
            with self.assertRaises(windows_msix.PackageError):
                windows_installer.package_version(bad)

    def test_bundle_file_name(self):
        self.assertEqual(windows_installer.bundle_file_name(VERSION), "JustSpeakToIt-windows_%s.msixbundle" % VERSION)


class AppInstallerTests(unittest.TestCase):
    def render(self, **overrides):
        values = dict(self_uri=windows_installer.APPINSTALLER_URI, bundle_uri=BUNDLE_URI, name=NAME,
                      publisher=PUBLISHER, version=VERSION)
        values.update(overrides)
        return windows_installer.render_appinstaller(**values)

    def test_published_file_states_the_bundle_and_update_policy(self):
        data = self.render()
        self.assertEqual(windows_installer.check_appinstaller(data, NAME, PUBLISHER, VERSION), BUNDLE_URI)
        self.assertIn(b'Uri="https://justspeaktoit.com/alpha/windows/JustSpeakToIt.appinstaller"', data)
        self.assertIn(b"<AutomaticBackgroundTask/>", data)

    def test_publisher_is_escaped(self):
        publisher = 'CN="Quoted, Name", C=GB'
        data = self.render(publisher=publisher)
        self.assertEqual(windows_installer.check_appinstaller(data, NAME, publisher, VERSION), BUNDLE_URI)

    def test_published_files_refuse_other_locations(self):
        for overrides in (
                {"self_uri": "https://example.com/JustSpeakToIt.appinstaller"},
                {"self_uri": "http://justspeaktoit.com/alpha/windows/JustSpeakToIt.appinstaller"},
                {"bundle_uri": BUNDLE_URI.replace("alpha-build-44", "alpha-latest")},
                {"bundle_uri": BUNDLE_URI.replace("crmitchelmore", "someone")},
                {"bundle_uri": BUNDLE_URI + "?x=1"},
                {"bundle_uri": "file:///C:/bundle.msixbundle"},
                {"publisher": "Example"}, {"version": "1.2.3"}, {"name": "bad name"}):
            with self.assertRaises(windows_msix.PackageError, msg=overrides):
                self.render(**overrides)

    def test_rehearsal_allows_local_files(self):
        data = self.render(self_uri="file:///C:/site/JustSpeakToIt.appinstaller",
                           bundle_uri="file:///C:/site/bundle.msixbundle", allow_any_uri=True)
        self.assertEqual(windows_installer.check_appinstaller(data, NAME, PUBLISHER, VERSION),
                         "file:///C:/site/bundle.msixbundle")

    def test_check_refuses_changed_files(self):
        data = self.render()
        for old, new in ((b'ShowPrompt="true"', b'ShowPrompt="false"'), (b"<AutomaticBackgroundTask/>", b""),
                         (PUBLISHER.encode(), b"CN=Other"), (b'Version="%s" Uri' % VERSION.encode(), b'Version="1.0.0.0" Uri'),
                         (b"<UpdateSettings>", b"<Dependencies/><UpdateSettings>"), (b"</AppInstaller>", b"")):
            changed = data.replace(old, new, 1)
            self.assertNotEqual(changed, data)
            with self.assertRaises(windows_msix.PackageError, msg=old):
                windows_installer.check_appinstaller(changed, NAME, PUBLISHER, VERSION)


def make_package(architecture, publisher=PUBLISHER, version=VERSION):
    identity = windows_msix.load_identity(windows_msix.BETA_IDENTITY_PATH)
    files = {windows_msix.APPX_MANIFEST: windows_msix.render_manifest(identity, version, publisher,
                                                                     architecture=architecture),
             "speak.exe": b"payload " + architecture.encode()}
    blockmap = '<BlockMap xmlns="%s" HashMethod="%s">%s</BlockMap>' % (
        windows_msix.BLOCKMAP_NAMESPACE, windows_msix.SHA256_METHOD, "".join(
            '<File Name="%s" Size="%d">%s</File>' % (name, len(data), "".join(
                '<Block Hash="%s"/>' % value for value in windows_msix.block_hashes(data)))
            for name, data in sorted(files.items())))
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        for name, data in files.items():
            archive.writestr(name, data)
        archive.writestr(windows_msix.BLOCKMAP_PART, blockmap)
        archive.writestr(windows_msix.CONTENT_TYPES_PART, "<Types></Types>")
    return buffer.getvalue()


def make_bundle(path, packages, version=VERSION, publisher=PUBLISHER, signed=False, extra=None, listed=None):
    rows = "".join('<b:Package Type="application" Version="%s" Architecture="%s" FileName="%s"/>' % (
        version, architecture, name) for architecture, name in (listed or {a: n for a, (n, _) in packages.items()}).items())
    manifest = ('<?xml version="1.0"?><b:Bundle xmlns:b="%s" SchemaVersion="5.0">'
                '<b:Identity Name="%s" Publisher="%s" Version="%s"/><b:Packages>%s</b:Packages></b:Bundle>') % (
        windows_installer.BUNDLE_NAMESPACE, NAME, publisher.replace('"', "&quot;"), version, rows)
    with zipfile.ZipFile(path, "w") as archive:
        for name, data in packages.values():
            archive.writestr(name, data)
        archive.writestr(windows_installer.BUNDLE_MANIFEST, manifest)
        archive.writestr(windows_msix.BLOCKMAP_PART, "<BlockMap/>")
        archive.writestr(windows_msix.CONTENT_TYPES_PART, "<Types/>")
        if signed:
            archive.writestr(windows_msix.SIGNATURE_PART, b"PKCX")
        for name, data in (extra or {}).items():
            archive.writestr(name, data)
    return path


class BundleVerificationTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.scratch.name)
        self.packages = {architecture: ("JustSpeakToIt-windows_%s_%s.msix" % (VERSION, architecture),
                                        make_package(architecture)) for architecture in ("x64", "arm64")}
        self.expected = {architecture: (name, hashlib.sha256(data).hexdigest())
                         for architecture, (name, data) in self.packages.items()}

    def tearDown(self):
        self.scratch.cleanup()

    def verify(self, path, signed=False, expected=None, publisher=PUBLISHER):
        return windows_installer.verify_bundle(path, NAME, publisher, VERSION, expected or self.expected, signed)

    def test_bundle_holds_exactly_both_beta_packages(self):
        unsigned = make_bundle(self.root / "unsigned.msixbundle", self.packages)
        result = self.verify(unsigned)
        self.assertEqual(sorted(result["packages"]), ["arm64", "x64"])
        self.assertEqual(result["packageFamilyName"], NAME + "_" + windows_msix.publisher_id(PUBLISHER))
        signed = make_bundle(self.root / "signed.msixbundle", self.packages, signed=True)
        self.assertTrue(self.verify(signed, signed=True)["signed"])
        with self.assertRaises(windows_msix.PackageError):
            self.verify(unsigned, signed=True)
        with self.assertRaises(windows_msix.PackageError):
            self.verify(signed, signed=False)

    def test_changed_bundles_are_refused(self):
        cases = {
            "missing arm64": dict(packages={"x64": self.packages["x64"]}),
            "extra file": dict(packages=self.packages, extra={"evil.dll": b"x"}),
            "other publisher": dict(packages=self.packages, publisher="CN=Other"),
            "other version": dict(packages=self.packages, version="2026.1030.1641.1"),
            "swapped architecture": dict(packages=self.packages, listed={
                "x64": self.packages["arm64"][0], "arm64": self.packages["x64"][0]}),
        }
        for label, options in cases.items():
            path = make_bundle(self.root / (label + ".msixbundle"), **options)
            with self.assertRaises(windows_msix.PackageError, msg=label):
                self.verify(path)
        tampered = dict(self.packages, x64=(self.packages["x64"][0], self.packages["x64"][1] + b"\0"))
        with self.assertRaises(windows_msix.PackageError):
            self.verify(make_bundle(self.root / "tampered.msixbundle", tampered))
        wrong_identity = dict(self.packages, x64=(self.packages["x64"][0], make_package("x64", publisher="CN=Other")))
        expected = dict(self.expected, x64=(self.packages["x64"][0], hashlib.sha256(wrong_identity["x64"][1]).hexdigest()))
        with self.assertRaises(windows_msix.PackageError):
            self.verify(make_bundle(self.root / "inner.msixbundle", wrong_identity), expected=expected)
        (self.root / "broken.msixbundle").write_bytes(b"not a zip")
        with self.assertRaises(windows_msix.PackageError):
            self.verify(self.root / "broken.msixbundle")

    def test_a_repacked_container_is_accepted_only_with_identical_entries(self):
        def repack(data, change=None):
            buffer = io.BytesIO()
            with zipfile.ZipFile(io.BytesIO(data)) as source, zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as out:
                for entry in source.namelist():
                    out.writestr(entry, (change or {}).get(entry, source.read(entry)))
            return buffer.getvalue()
        originals = {architecture: data for architecture, (_, data) in self.packages.items()}
        repacked = {architecture: (name, repack(data)) for architecture, (name, data) in self.packages.items()}
        path = make_bundle(self.root / "repacked.msixbundle", repacked)
        with self.assertRaises(windows_msix.PackageError):
            self.verify(path)
        result = windows_installer.verify_bundle(path, NAME, PUBLISHER, VERSION, self.expected, False, originals)
        self.assertTrue(result["packages"]["x64"]["repacked"])
        changed = dict(repacked, x64=(repacked["x64"][0], repack(originals["x64"], {"speak.exe": b"other"})))
        with self.assertRaisesRegex(windows_msix.PackageError, "speak.exe"):
            windows_installer.verify_bundle(make_bundle(self.root / "changed.msixbundle", changed), NAME, PUBLISHER,
                                            VERSION, self.expected, False, originals)

    def test_signing_the_bundle_may_sign_inner_packages_without_changing_their_payload(self):
        def sign(data, extra=None, blockmap=None):
            buffer = io.BytesIO()
            with zipfile.ZipFile(io.BytesIO(data)) as source, zipfile.ZipFile(buffer, "w") as out:
                for entry in source.namelist():
                    content = source.read(entry)
                    if entry == windows_msix.BLOCKMAP_PART:
                        content = blockmap if blockmap is not None else content.replace(
                            b"</BlockMap>", b'<File Name="AppxMetadata\\CodeIntegrity.cat" Size="3"/></BlockMap>')
                    if entry == windows_msix.CONTENT_TYPES_PART:
                        content = content.replace(b"</Types>", b'<Default Extension="p7x" ContentType="x"/></Types>')
                    out.writestr(entry, content)
                out.writestr(windows_msix.SIGNATURE_PART, b"PKCX")
                out.writestr(windows_msix.CODE_INTEGRITY_PART, b"cat")
                for entry, content in (extra or {}).items():
                    out.writestr(entry, content)
            return buffer.getvalue()
        originals = {architecture: data for architecture, (_, data) in self.packages.items()}
        signed = {architecture: (name, sign(data)) for architecture, (name, data) in self.packages.items()}
        path = make_bundle(self.root / "signed.msixbundle", signed, signed=True)
        result = windows_installer.verify_bundle(path, NAME, PUBLISHER, VERSION, self.expected, True, originals)
        self.assertTrue(result["packages"]["arm64"]["repacked"])
        with self.assertRaises(windows_msix.PackageError):
            windows_installer.verify_bundle(make_bundle(self.root / "unsigned-inner.msixbundle", signed), NAME,
                                            PUBLISHER, VERSION, self.expected, False, originals)
        for label, inner in (("extra entry", sign(originals["x64"], {"evil.dll": b"x"})),
                             ("rewritten block map", sign(originals["x64"], blockmap=b'<BlockMap xmlns="%s" HashMethod="x"/>'
                                                          % windows_msix.BLOCKMAP_NAMESPACE.encode()))):
            tampered = dict(signed, x64=(signed["x64"][0], inner))
            with self.assertRaises(windows_msix.PackageError, msg=label):
                windows_installer.verify_bundle(make_bundle(self.root / (label + ".msixbundle"), tampered, signed=True),
                                                NAME, PUBLISHER, VERSION, self.expected, True, originals)


if __name__ == "__main__":
    unittest.main()
