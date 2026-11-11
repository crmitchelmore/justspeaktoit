#!/usr/bin/env python3
"""Application inputs, the pinned Swift runtime source and the committed runtime locks."""
import hashlib
import json
import pathlib
import struct
import sys
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))
from bundle_test_fixtures import BUILD, PE, build_pe  # noqa: E402


class ApplicationInputTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.app = pathlib.Path(self.directory.name)
        self.policy = BUILD.Policy.load()
        self.executable = build_pe(["KERNEL32.dll", "swiftCore.dll"])
        (self.app / "SpeakWindows.exe").write_bytes(self.executable)
        self.cli = build_pe(["KERNEL32.dll", "swiftCore.dll"], ["Foundation.dll"])
        (self.app / "speak.exe").write_bytes(self.cli)
        (self.app / "SpeakAppPackageTests.exe").write_bytes(build_pe(["XCTest.dll"]))
        (self.app / "SpeakApp_SpeakCore.resources").mkdir()
        (self.app / "SpeakApp_SpeakCore.resources/Info.plist").write_bytes(b"<plist/>")
        (self.app / "SpeakApp_SpeakWindowsPlatformTests.resources/Fixtures").mkdir(parents=True)
        (self.app / "SpeakApp_SpeakWindowsPlatformTests.resources/Fixtures/tone.m4a").write_bytes(b"audio")
        self.metadata = {"host": "Darwin", "target": "x86_64-unknown-windows-msvc", "configuration": "release",
                         "appBuiltForTesting": False, "sourceCommit": "abc",
                         "executables": {"SpeakWindows.exe": hashlib.sha256(self.executable).hexdigest(),
                                         "speak.exe": hashlib.sha256(self.cli).hexdigest()}}
        self.write_metadata()

    def write_metadata(self):
        (self.app / "app-build-metadata.json").write_text(json.dumps(self.metadata), encoding="utf-8")

    def test_production_executable_and_non_test_resources_are_loaded(self):
        application = BUILD.load_application(self.app, self.policy)
        self.assertEqual(application["executables"], {"SpeakWindows.exe": self.executable, "speak.exe": self.cli})
        self.assertEqual(list(application["resources"]), ["SpeakApp_SpeakCore.resources/Info.plist"])

    def test_all_eight_recording_feedback_assets_are_collected_byte_exact(self):
        sounds = HERE.parent.parent / "Resources" / "Sounds"
        expected_names = {
            "recording_start.m4a", "recording_stop.m4a",
            "recording_start_bubbly.m4a", "recording_stop_bubbly.m4a",
            "recording_start_futuristic.m4a", "recording_stop_futuristic.m4a",
            "recording_start_soft.m4a", "recording_stop_soft.m4a",
        }
        self.assertEqual({path.name for path in sounds.iterdir()}, expected_names)
        directory = self.app / "SpeakApp_SpeakFeedbackResources.resources" / "Sounds"
        directory.mkdir(parents=True)
        expected = {}
        for name in sorted(expected_names):
            body = (sounds / name).read_bytes()
            self.assertEqual(body[4:8], b"ftyp")
            self.assertGreater(len(body), 12)
            self.assertLessEqual(len(body), 1_048_576)
            (directory / name).write_bytes(body)
            expected["SpeakApp_SpeakFeedbackResources.resources/Sounds/" + name] = body
        resources = BUILD.load_application(self.app, self.policy)["resources"]
        expected["SpeakApp_SpeakCore.resources/Info.plist"] = b"<plist/>"
        self.assertEqual(resources, expected)

    def test_debug_or_test_enabled_metadata_is_refused(self):
        for key, value in [("configuration", "debug"), ("appBuiltForTesting", True), ("host", "Windows")]:
            metadata = dict(self.metadata)
            metadata[key] = value
            (self.app / "app-build-metadata.json").write_text(json.dumps(metadata), encoding="utf-8")
            with self.assertRaisesRegex(BUILD.BundleError, key):
                BUILD.load_application(self.app, self.policy)

    def test_hash_mismatch_and_test_imports_are_refused(self):
        (self.app / "SpeakWindows.exe").write_bytes(build_pe(["KERNEL32.dll"]))
        with self.assertRaisesRegex(BUILD.BundleError, "hash"):
            BUILD.load_application(self.app, self.policy)
        tested = build_pe(["KERNEL32.dll"], ["Testing.dll"])
        (self.app / "SpeakWindows.exe").write_bytes(tested)
        self.metadata["executables"]["SpeakWindows.exe"] = hashlib.sha256(tested).hexdigest()
        self.write_metadata()
        with self.assertRaisesRegex(BUILD.BundleError, "test-enabled"):
            BUILD.load_application(self.app, self.policy)

    def test_symlinked_resource_is_refused(self):
        target = self.app / "outside.txt"
        target.write_bytes(b"outside")
        (self.app / "SpeakApp_SpeakCore.resources/link.txt").symlink_to(target)
        with self.assertRaisesRegex(BUILD.BundleError, "symbolic link"):
            BUILD.load_application(self.app, self.policy)

    def test_cli_missing_hash_drift_wrong_architecture_tests_and_gui_subsystem_are_refused(self):
        path = self.app / "speak.exe"
        path.unlink()
        with self.assertRaisesRegex(BUILD.BundleError, "missing production executable.*speak.exe"):
            BUILD.load_application(self.app, self.policy)
        path.write_bytes(self.cli + b"tamper")
        with self.assertRaisesRegex(BUILD.BundleError, "speak.exe.*hash"):
            BUILD.load_application(self.app, self.policy)
        for data, reason in (
            (build_pe(machine=PE.IMAGE_FILE_MACHINE_ARM64), "not a Windows x64 executable"),
            (build_pe(delay_imports=["Testing.dll"]), "test-enabled"),
            (build_pe(dll=True), "not a Windows x64 executable"),
        ):
            path.write_bytes(data)
            self.metadata["executables"]["speak.exe"] = hashlib.sha256(data).hexdigest()
            self.write_metadata()
            with self.assertRaisesRegex(BUILD.BundleError, reason):
                BUILD.load_application(self.app, self.policy)
        data = bytearray(self.cli)
        struct.pack_into("<H", data, struct.unpack_from("<I", data, 0x3c)[0] + 24 + 68, 2)
        path.write_bytes(data)
        self.metadata["executables"]["speak.exe"] = hashlib.sha256(data).hexdigest()
        self.write_metadata()
        with self.assertRaisesRegex(BUILD.BundleError, "console subsystem"):
            BUILD.load_application(self.app, self.policy)

    def test_future_production_resource_bundles_are_preserved(self):
        path = self.app / "SpeakApp_FutureFeature.resources" / "nested"
        path.mkdir(parents=True)
        (path / "catalog.json").write_bytes(b'{"future": true}')
        resources = BUILD.load_application(self.app, self.policy)["resources"]
        self.assertEqual(resources["SpeakApp_FutureFeature.resources/nested/catalog.json"], b'{"future": true}')

    def test_test_support_fixtures_stay_in_producer_but_out_of_production(self):
        for name in ("SpeakTestSupport", "SpeakApp_SpeakTestSupport", "SpeakApp_SpeakTestSupportTools"):
            directory = self.app / (name + ".resources")
            directory.mkdir()
            (directory / "fixture.json").write_bytes(b"fixture bytes")
        resources = BUILD.load_application(self.app, self.policy)["resources"]
        self.assertEqual(resources, {
            "SpeakApp_SpeakCore.resources/Info.plist": b"<plist/>",
            "SpeakApp_SpeakTestSupportTools.resources/fixture.json": b"fixture bytes",
        })
        for name in ("SpeakTestSupport", "SpeakApp_SpeakTestSupport"):
            self.assertEqual((self.app / (name + ".resources") / "fixture.json").read_bytes(), b"fixture bytes")


class SwiftRuntimeSourceTests(unittest.TestCase):
    MANIFEST = ('<BurnManifest xmlns="http://wixtoolset.org/schemas/v4/2008/Burn">'
                '<Payload Id="a0" FilePath="rtl.msi" FileSize="450560" Hash="ABC" SourcePath="a0"/>'
                '<Payload Id="a7" FilePath="rtl.cab" FileSize="18542881" Hash="DEF" SourcePath="a7"/>'
                '<Payload Id="a6" FilePath="windows.msi" FileSize="1" Hash="123" SourcePath="a6"/></BurnManifest>')

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.cache = pathlib.Path(self.directory.name)
        (self.cache / "swift-windows").mkdir()
        (self.cache / "windows-extraction/bootstrap").mkdir(parents=True)
        (self.cache / "windows-extraction/bootstrap/0").write_text(self.MANIFEST, encoding="utf-8")
        data = build_pe(["KERNEL32.dll"], dll=True)
        (self.cache / "swift-windows/swiftCore.dll").write_bytes(data)
        (self.cache / "windows-extraction/rtl-layout.json").write_text(json.dumps(
            [{"path": "swiftCore.dll", "cabinet": "rtl.cab", "id": "filCore", "bytes": len(data)}]), encoding="utf-8")
        cross = json.loads((HERE.parent / "windows-cross/dependencies.json").read_text(encoding="utf-8"))
        installer = next(item for item in cross["downloads"] if item["name"].endswith("-windows10.exe"))
        self.lock_path = self.cache / "source-lock.json"
        self.lock = {"architecture": "x64", "swiftVersion": "6.2.3", "installer": installer,
                     "bootstrapManifestSHA256": "fixture", "payloads": {
                         "rtl.msi": {"bytes": 450560, "sha512": "abc"}, "rtl.cab": {"bytes": 18542881, "sha512": "def"}},
                     "files": [{"path": "swiftCore.dll", "cabinet": "rtl.cab", "id": "filCore", "bytes": len(data),
                                "sha256": hashlib.sha256(data).hexdigest()}]}
        self.write_lock(self.lock)
        self.runtime = self.cache / "swift-windows"

    def write_lock(self, lock):
        self.lock_path.write_text(json.dumps(lock), encoding="utf-8")

    def arm64_lock(self, **installer_changes):
        pins = json.loads((HERE / "dependencies.json").read_text(encoding="utf-8"))
        pin = pins["swiftRuntimeInstallers"]["arm64"]
        installer = {key: pin[key] for key in ("name", "url", "sha256", "bytes")}
        installer.update(installer_changes)
        return dict(self.lock, architecture="arm64", installer=installer)

    def test_runtime_package_provenance_and_modules_are_read(self):
        source = BUILD.load_swift_runtime(self.runtime, self.lock_path)
        self.assertEqual(source["payloads"], {"rtl.msi": {"bytes": 450560, "sha512": "abc"},
                                              "rtl.cab": {"bytes": 18542881, "sha512": "def"}})
        self.assertEqual(source["swiftVersion"], "6.2.3")
        self.assertEqual(source["installer"]["name"], "swift-6.2.3-RELEASE-windows10.exe")
        self.assertEqual(source["pinFile"], "scripts/windows-cross/dependencies.json")
        data, provenance = BUILD.read_swift_module(source, "swiftCore.dll")
        self.assertEqual(provenance["fileKey"], "filCore")
        self.assertEqual(provenance["package"], "rtl.msi")
        with self.assertRaisesRegex(BUILD.BundleError, "does not provide"):
            BUILD.read_swift_module(source, "swiftWinSDK.dll")

    def test_missing_provenance_is_refused(self):
        self.lock_path.unlink()
        with self.assertRaisesRegex(BUILD.BundleError, "provenance"):
            BUILD.load_swift_runtime(self.runtime, self.lock_path)

    def test_same_size_tamper_is_refused_even_with_changed_cache_metadata(self):
        path = self.cache / "swift-windows/swiftCore.dll"
        changed = bytearray(path.read_bytes())
        changed[-1] ^= 1
        path.write_bytes(changed)
        (self.cache / "windows-extraction/rtl-layout.json").write_text("[]", encoding="utf-8")
        (self.cache / "windows-extraction/bootstrap/0").write_text("substituted metadata", encoding="utf-8")
        source = BUILD.load_swift_runtime(self.runtime, self.lock_path)
        with self.assertRaisesRegex(BUILD.BundleError, "checksum"):
            BUILD.read_swift_module(source, "swiftCore.dll")

    def test_source_lock_must_match_cross_installer_pin(self):
        for changes in [{"installer": dict(self.lock["installer"], sha256="0" * 64)},
                        {"installer": dict(self.lock["installer"], bytes=self.lock["installer"]["bytes"] + 1)},
                        {"architecture": "arm64"}, {"architecture": None}, {"swiftVersion": "6.3"}]:
            self.write_lock(dict(self.lock, **changes))
            with self.assertRaisesRegex(BUILD.BundleError, "installer"):
                BUILD.load_swift_runtime(self.runtime, self.lock_path)

    def test_arm64_lock_names_the_pinned_arm64_installer(self):
        self.write_lock(self.arm64_lock())
        source = BUILD.load_swift_runtime(self.runtime, self.lock_path, "arm64")
        self.assertEqual(source["installer"]["name"], "swift-6.2.3-RELEASE-windows10-arm64.exe")
        self.assertEqual(source["installer"]["bytes"], 635789872)
        self.assertEqual(source["pinFile"], "scripts/windows-bundle/dependencies.json")
        # Size and SHA-256 are both exact: a lock for any other download is refused.
        for changes in [{"bytes": 635789873}, {"bytes": 635789871}, {"bytes": 0}, {"sha256": "0" * 64},
                        {"url": "https://download.swift.org/other.exe"}, {"bytes": "635789872"}]:
            self.write_lock(self.arm64_lock(**changes))
            with self.assertRaisesRegex(BUILD.BundleError, "pinned arm64 installer"):
                BUILD.load_swift_runtime(self.runtime, self.lock_path, "arm64")
        # An x64 lock never stands in for ARM64.
        self.write_lock(self.lock)
        with self.assertRaisesRegex(BUILD.BundleError, "pinned arm64 installer"):
            BUILD.load_swift_runtime(self.runtime, self.lock_path, "arm64")
        # A pin that only bounds the size is not a pin.
        with self.assertRaisesRegex(ValueError, "lacks its exact byte count"):
            BUILD.windows_targets.installer_size_matches({"name": "x.exe", "maximumBytes": 10}, 5)


class CommittedRuntimeLockTests(unittest.TestCase):
    """The committed Swift runtime locks agree with their installer pins and the runtime policy."""

    def committed(self, architecture):
        path = HERE / BUILD.windows_targets.target(architecture)["swiftRuntimeLock"]
        return path, json.loads(path.read_text(encoding="utf-8"))

    def test_each_lock_names_its_pinned_installer_and_loads_only_for_its_architecture(self):
        with tempfile.TemporaryDirectory() as directory:
            runtime = pathlib.Path(directory)
            for architecture, other in [("x64", "arm64"), ("arm64", "x64")]:
                path, lock = self.committed(architecture)
                swift_version, pin, _ = BUILD.windows_targets.swift_runtime_installer(architecture)
                self.assertEqual(lock["installer"], {key: pin[key] for key in ("name", "url", "sha256", "bytes")})
                self.assertEqual((lock["architecture"], lock["swiftVersion"]), (architecture, swift_version))
                self.assertEqual(BUILD.load_swift_runtime(runtime, path, architecture)["installer"]["bytes"],
                                 pin["bytes"])
                with self.assertRaisesRegex(BUILD.BundleError, "pinned %s installer" % other):
                    BUILD.load_swift_runtime(runtime, path, other)

    def test_locked_files_are_authenticated_runtime_dlls_the_policy_classifies(self):
        policy = BUILD.Policy.load()
        for architecture in ("x64", "arm64"):
            _, lock = self.committed(architecture)
            self.assertEqual(sorted(lock["payloads"]), ["rtl.cab", "rtl.msi"])
            for receipt in lock["payloads"].values():
                self.assertRegex(receipt["sha512"], "^[0-9a-f]{128}$")
            paths = [row["path"] for row in lock["files"]]
            self.assertEqual(len({path.lower() for path in paths}), len(paths))
            for row in lock["files"]:
                self.assertEqual(BUILD.check_bundle_path(row["path"]), row["path"])
                self.assertNotIn("/", row["path"])
                self.assertRegex(row["sha256"], "^[0-9a-f]{64}$")
                self.assertIn(policy.classify(row["path"]), (BUILD.SWIFT_RUNTIME, BUILD.MICROSOFT_RUNTIME),
                              "%s %s" % (architecture, row["path"]))


if __name__ == "__main__":
    unittest.main()
