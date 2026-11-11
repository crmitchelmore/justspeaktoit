#!/usr/bin/env python3
"""Unit tests for Windows runtime bundle assembly; no downloads or caches.

Sibling test_windows_bundle_*.py files cover PE reading and closure, inputs,
redistributables and the local runtime. Other tooling tests load this module for
build_pe, PE, BUILD, MIGRATION and AssemblyTests.
"""
import hashlib
import json
import pathlib
import sys
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))
from bundle_test_fixtures import (  # noqa: E402,F401
    BUILD, LOCAL_ARM64_GRAPH, LOCAL_GRAPH, LOCAL_PINS, MACHINES, MIGRATION, PE, write_local_runtime,
)
from pe_test_fixtures import build_pe  # noqa: E402


class AssemblyTests(unittest.TestCase):
    def setUp(self, architecture="x64"):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        root = pathlib.Path(self.directory.name)
        self.policy = BUILD.Policy.load()
        self.runtime = root / "runtime"
        self.runtime.mkdir()
        machine = MACHINES[architecture]
        # Microsoft's ARM64 runtime DLLs are ARM64X images; the fixture mirrors that.
        hybrid = 0x1800325E8 if architecture == "arm64" else None
        modules = {"swiftCore.dll": (["KERNEL32.dll", "VCRUNTIME140.dll", "MSVCP140.dll"], []),
                   "Foundation.dll": (["swiftCore.dll", "_FoundationICU.dll"], []),
                   "_FoundationICU.dll": (["msvcp140.dll", "KERNEL32.dll"], []),
                   "swiftWinSDK.dll": (["swiftCore.dll"], [])}
        layout = {}
        for name, (static, delayed) in modules.items():
            data = build_pe(static, delayed, dll=True, machine=machine)
            (self.runtime / name).write_bytes(data)
            layout[name] = {"path": name, "cabinet": "rtl.cab", "id": "fil" + name, "bytes": len(data),
                            "sha256": hashlib.sha256(data).hexdigest()}
        installer = ("swift-6.2.3-RELEASE-windows10.exe" if architecture == "x64"
                     else "swift-6.2.3-RELEASE-windows10-arm64.exe")
        self.swift = {"directory": self.runtime, "layout": layout,
                      "payloads": {"rtl.msi": {"bytes": 1, "sha512": "a"}, "rtl.cab": {"bytes": 2, "sha512": "b"}},
                      "installer": {"name": installer, "sha256": "c", "bytes": 3, "url": "https://x"},
                      "swiftVersion": "6.2.3", "lockSHA256": "fixture", "bootstrapManifestSHA256": "fixture",
                      "pinFile": "scripts/windows-cross/dependencies.json" if architecture == "x64"
                      else "scripts/windows-bundle/dependencies.json"}
        self.microsoft = {"modules": {}, "version": "14.51.36247.0",
                          "displayName": "Microsoft Visual C++ v14 Redistributable (x64) - 14.51.36247",
                          "productName": "Microsoft Visual C++ 2022 X64 Minimum Runtime - 14.51.36247"
                          if architecture == "x64" else "Microsoft Visual C++ 2022 Arm64 Runtime - 14.51.36247"}
        for name, static in [("msvcp140.dll", ["vcruntime140.dll", "api-ms-win-crt-heap-l1-1-0.dll"]),
                             ("vcruntime140.dll", ["KERNEL32.dll"]), ("concrt140.dll", ["msvcp140.dll"])]:
            data = build_pe(static, dll=True, version=((14, 51, 36247, 0), {"OriginalFilename": name}),
                            machine=machine, hybrid_metadata=hybrid)
            self.microsoft["modules"][name] = {"name": name, "bytes": data, "provenance": {"fileVersion": "14.51.36247.0", "fileKey": name + "_amd64"}}
        self.executable = build_pe(["USER32.dll", "swiftCore.dll", "MSVCP140.dll"], ["Foundation.dll"], machine=machine)
        self.application = {"metadata": {"sourceCommit": "0123456789abcdef", "configuration": "release",
                                         "host": BUILD.APPLICATION_HOSTS[architecture],
                                         "target": BUILD.windows_targets.target(architecture)["swiftTriple"],
                                         "appBuiltForTesting": False, "swiftCompiler": "swift", "nativeCompiler": "clang"},
                            "executables": {"SpeakWindows.exe": self.executable,
                                            "speak.exe": build_pe(["swiftCore.dll", "KERNEL32.dll"], machine=machine)},
                            "resources": {"SpeakApp_SpeakCore.resources/Info.plist": b"<plist/>"}}
        self.application["metadata"]["executables"] = {
            name: hashlib.sha256(data).hexdigest() for name, data in self.application["executables"].items()}
        self.licenses = [{"name": "LICENSE-swift.txt", "url": "https://x/swift", "sha256": "d", "bytes": 5,
                          "license": "Apache License 2.0 with Runtime Library Exception", "covers": "Swift", "data": b"Apache"},
                         {"name": "LICENSE-icu.txt", "url": "https://x/icu", "sha256": "e", "bytes": 6,
                          "license": "Unicode License v3", "covers": "ICU 74.1 compiled into _FoundationICU.dll", "data": b"Unicode"}]
        self.lock = {"name": "VC_redist.x64.exe", "url": "https://x/vc", "sha256": "f", "bytes": 7,
                     "permalink": "https://aka.ms/x", "version": "14.51.36247.0",
                     "packages": json.loads((HERE / "dependencies.json").read_text(encoding="utf-8"))
                     ["microsoftRuntime"]["packages"]}
        self.messages = []

    def assemble(self, **overrides):
        arguments = dict(application=self.application, swift=self.swift, microsoft=self.microsoft,
                         licenses=self.licenses, app_license=b"MIT License\n", policy=self.policy, lock=self.lock,
                         cross_check=None, log=self.messages.append)
        arguments.update(overrides)
        return BUILD.assemble(**arguments)

    def test_native_zip_license_and_provenance_are_bundled(self):
        license_entry = MIGRATION.license_entry(HERE.parents[1])
        entries, manifest = self.assemble(licenses=self.licenses + [license_entry])
        self.assertEqual(entries["licenses/LICENSE-miniz.txt"], license_entry["data"])
        self.assertIn("LICENSE-miniz.txt", entries["THIRD-PARTY-NOTICES.txt"].decode())
        self.assertIn("miniz 3.1.2", entries["THIRD-PARTY-NOTICES.txt"].decode())
        row = next(item for item in manifest["sources"]["licenses"] if item["name"] == "LICENSE-miniz.txt")
        self.assertEqual(row["sha256"], hashlib.sha256(license_entry["data"]).hexdigest())
        self.assertEqual(row["license"], "MIT")

    def test_bundle_contains_only_the_closure_resources_licences_and_notices(self):
        entries, manifest = self.assemble()
        self.assertEqual(sorted(entries), [
            "Foundation.dll", "README.txt", "SpeakApp_SpeakCore.resources/Info.plist", "SpeakWindows.exe",
            "THIRD-PARTY-NOTICES.txt", "_FoundationICU.dll", "licenses/LICENSE-JustSpeakToIt.txt",
            "licenses/LICENSE-icu.txt", "licenses/LICENSE-swift.txt", "licenses/NOTICE-microsoft-visual-cpp-runtime.txt",
            "msvcp140.dll", "speak.exe", "swiftCore.dll", "vcruntime140.dll"])
        self.assertNotIn("swiftWinSDK.dll", entries)
        self.assertNotIn("concrt140.dll", entries)
        self.assertEqual([item["path"] for item in manifest["files"]], sorted(entries))
        for item in manifest["files"]:
            self.assertEqual(item["sha256"], hashlib.sha256(entries[item["path"]]).hexdigest())
            self.assertEqual(item["bytes"], len(entries[item["path"]]))
        self.assertEqual(list(manifest["dependencies"]["bundled"]),
                         ["_foundationicu.dll", "foundation.dll", "msvcp140.dll", "swiftcore.dll", "vcruntime140.dll"])
        self.assertEqual(sorted(manifest["dependencies"]["system"]), ["api-ms-win-crt-heap-l1-1-0.dll", "kernel32.dll", "user32.dll"])
        vcruntime = next(item for item in manifest["files"] if item["path"] == "vcruntime140.dll")
        self.assertEqual(vcruntime["fileVersion"], "14.51.36247.0")
        self.assertEqual(vcruntime["source"], BUILD.MICROSOFT_RUNTIME)
        self.assertIn("14.51.36247", entries["THIRD-PARTY-NOTICES.txt"].decode())
        self.assertIn("LICENSE-icu.txt", entries["THIRD-PARTY-NOTICES.txt"].decode())
        self.assertIn("0123456789abcdef", entries["README.txt"].decode())
        self.assertEqual(manifest["application"]["executableSHA256"], hashlib.sha256(self.executable).hexdigest())
        self.assertEqual(manifest["application"]["executables"], self.application["metadata"]["executables"])
        self.assertEqual(entries["speak.exe"], self.application["executables"]["speak.exe"])

    def test_cli_only_runtime_is_in_union_but_not_required_by_gui(self):
        architecture = PE.PEImage(self.executable).architecture
        cli = build_pe(["swiftWinSDK.dll", "swiftCore.dll"], ["Foundation.dll"], machine=MACHINES[architecture])
        self.application["executables"]["speak.exe"] = cli
        self.application["metadata"]["executables"]["speak.exe"] = hashlib.sha256(cli).hexdigest()
        entries, manifest = self.assemble()
        self.assertIn("swiftWinSDK.dll", entries)
        deps = manifest["dependencies"]
        self.assertEqual(deps["bundled"]["swiftwinsdk.dll"]["importedBy"],
                         [{"importer": "speak.exe", "kind": "static"}])
        self.assertNotIn("swiftWinSDK.dll", deps["roots"]["SpeakWindows.exe"]["staticModules"])
        self.assertIn("swiftWinSDK.dll", deps["roots"]["speak.exe"]["staticModules"])
        self.assertNotIn("Foundation.dll", deps["roots"]["speak.exe"]["staticModules"])

    def test_assembly_refuses_missing_or_unauthenticated_cli(self):
        cli = self.application["executables"].pop("speak.exe")
        with self.assertRaisesRegex(BUILD.BundleError, "requires exactly"):
            self.assemble()
        self.application["executables"]["speak.exe"] = cli + b"tampered"
        with self.assertRaisesRegex(BUILD.BundleError, "speak.exe.*hash"):
            self.assemble()

    def test_pinned_licences_cover_embedded_networking_dependencies(self):
        lock = json.loads((HERE / "dependencies.json").read_text(encoding="utf-8"))
        for name in ["curl", "zlib"]:
            entry = next(item for item in lock["licenses"] if item["name"] == "LICENSE-" + name + ".txt")
            self.assertEqual(len(entry["sha256"]), 64)
            self.assertIn("FoundationNetworking.dll", entry["covers"])
            self.licenses.append(dict(entry, data=b"fixture licence"))
        entries, manifest = self.assemble()
        for name in ["curl", "zlib"]:
            self.assertIn("licenses/LICENSE-" + name + ".txt", entries)
            self.assertIn("LICENSE-" + name + ".txt", entries["THIRD-PARTY-NOTICES.txt"].decode())

    def test_assembly_is_deterministic(self):
        first, first_manifest = self.assemble()
        second, second_manifest = self.assemble()
        self.assertEqual(first, second)
        self.assertEqual(json.dumps(first_manifest, sort_keys=True), json.dumps(second_manifest, sort_keys=True))

    def test_runtime_module_missing_from_pinned_sources_is_refused(self):
        del self.microsoft["modules"]["vcruntime140.dll"]
        with self.assertRaisesRegex(BUILD.BundleError, "does not provide vcruntime140.dll"):
            self.assemble()
        self.setUp()
        (self.runtime / "Foundation.dll").unlink()
        with self.assertRaisesRegex(BUILD.BundleError, "does not provide Foundation.dll"):
            self.assemble()

    def test_runtime_file_size_drift_is_refused(self):
        self.swift["layout"]["swiftCore.dll"]["bytes"] += 1
        with self.assertRaisesRegex(BUILD.BundleError, "layout size"):
            self.assemble()

    def test_local_runtime_is_bundled_with_its_licence_and_provenance(self):
        pins = write_local_runtime(pathlib.Path(self.directory.name) / "local")
        local = BUILD.load_local_runtime(pathlib.Path(self.directory.name) / "local", pins)
        for name in ["concrt140.dll"]:
            self.microsoft["modules"][name]["bytes"] = build_pe(["KERNEL32.dll"], dll=True, version=(
                (14, 51, 36247, 0), {"OriginalFilename": name}))
        policy = BUILD.Policy.load(local_runtime=[module["name"] for module in local["modules"].values()])
        entries, manifest = self.assemble(policy=policy, local_runtime=local)
        for name in LOCAL_GRAPH:
            self.assertIn(name, entries)
            row = next(item for item in manifest["files"] if item["path"] == name)
            self.assertEqual(row["source"], BUILD.LOCAL_RUNTIME)
            self.assertIn({"importer": "SpeakWindows.exe", "kind": "runtime-loaded"},
                          manifest["dependencies"]["bundled"][name.lower()]["importedBy"])
            self.assertFalse(any(ref["importer"] == "speak.exe" for ref in
                                 manifest["dependencies"]["bundled"][name.lower()]["importedBy"]))
        self.assertIn("concrt140.dll", entries)
        self.assertIn("licenses/LICENSE-whisper.cpp.txt", entries)
        notices = entries["THIRD-PARTY-NOTICES.txt"].decode()
        self.assertIn("whisper.cpp " + LOCAL_PINS["whisperCpp"]["version"], notices)
        self.assertIn("vulkan-1.dll is not redistributed", notices)
        self.assertEqual(manifest["sources"]["localInferenceRuntime"]["commit"], LOCAL_PINS["whisperCpp"]["commit"])
        self.assertNotIn("vulkan-1.dll", entries)
        self.assertIn("Vulkan GPU", entries["README.txt"].decode())
        with self.assertRaisesRegex(BUILD.BundleError, "not loaded with the local runtime"):
            self.assemble(local_runtime=local)

    def test_cpu_only_local_runtime_is_described_without_a_gpu_backend(self):
        root = pathlib.Path(self.directory.name) / "local-arm64"
        local = BUILD.load_local_runtime(root, write_local_runtime(root, graph=LOCAL_ARM64_GRAPH, architecture="arm64"),
                                         "arm64")
        # The runtime fixture is ARM64; the rest of this fixture stays x64 until
        # the bundle itself is assembled for ARM64, so only the text is checked.
        readme = BUILD.readme_text(self.application["metadata"], [], self.microsoft, local)
        notices = BUILD.notices_text("LICENSE-JustSpeakToIt.txt", [], [], self.microsoft, self.lock, self.licenses, local)
        self.assertIn("It runs on the CPU; this build has no GPU backend", readme)
        self.assertNotIn("Vulkan", readme)
        self.assertIn("CPU backend only, no GPU backend", notices)
        self.assertNotIn("vulkan-1.dll", notices)

    def test_forbidden_resource_files_are_refused(self):
        self.application["resources"]["SpeakApp_SpeakCore.resources/swiftCore.lib"] = b"lib"
        with self.assertRaisesRegex(BUILD.BundleError, "forbids"):
            self.assemble()

    def test_x64_bundle_records_image_architecture_and_refuses_arm64ec(self):
        entries, manifest = self.assemble()
        self.assertEqual(manifest["bundle"]["architecture"], "x86_64")
        self.assertEqual(manifest["bundle"]["kind"], "unsigned Windows x64 developer runtime bundle")
        self.assertEqual({row["imageArchitecture"] for row in manifest["files"] if "imageArchitecture" in row}, {"x64"})
        self.assertEqual(manifest["application"]["imageArchitecture"], "x64")
        self.assertIn("64-bit Windows 10 or", entries["README.txt"].decode())
        self.assertIn("pinned in scripts/windows-cross/dependencies.json", entries["THIRD-PARTY-NOTICES.txt"].decode())
        self.microsoft["modules"]["vcruntime140.dll"]["bytes"] = build_pe(["KERNEL32.dll"], dll=True,
                                                                          hybrid_metadata=0x18000A2E8)
        with self.assertRaisesRegex(BUILD.BundleError, "vcruntime140.dll is not a native x64 DLL \\(it is arm64ec\\)"):
            self.assemble()


class ARM64AssemblyTests(AssemblyTests):
    """The same assembly for an ARM64 bundle: native ARM64 and ARM64X images only."""

    def setUp(self):
        super().setUp("arm64")

    def assemble(self, **overrides):
        return super().assemble(**dict({"architecture": "arm64"}, **overrides))

    def test_x64_bundle_records_image_architecture_and_refuses_arm64ec(self):
        self.skipTest("x64 only")

    def test_local_runtime_is_bundled_with_its_licence_and_provenance(self):
        self.skipTest("the x64 runtime fixture includes the Vulkan backend; see the CPU-only case")

    def test_arm64_bundle_is_described_and_holds_only_native_images(self):
        entries, manifest = self.assemble()
        self.assertEqual(manifest["bundle"]["architecture"], "aarch64")
        self.assertEqual(manifest["bundle"]["kind"], "unsigned Windows ARM64 developer runtime bundle")
        self.assertTrue(manifest["bundle"]["requires"].startswith("Windows 10 or later on ARM64"))
        self.assertEqual(manifest["application"]["imageArchitecture"], "arm64")
        architectures = {row["path"]: row["imageArchitecture"] for row in manifest["files"] if "imageArchitecture" in row}
        self.assertEqual(architectures["msvcp140.dll"], "arm64x")
        self.assertEqual(architectures["swiftCore.dll"], "arm64")
        self.assertIn("arm64x", manifest["verification"]["imageArchitecture"])
        readme = entries["README.txt"].decode()
        self.assertIn("Windows ARM64 developer runtime bundle", readme)
        self.assertIn("an ARM64 PC", readme)
        self.assertIn("Microsoft Visual C++ 2022 Arm64 Runtime", readme)
        notices = entries["THIRD-PARTY-NOTICES.txt"].decode()
        self.assertIn("Windows ARM64 installer runtime package (rtl.msi), pinned in scripts/windows-bundle/dependencies.json",
                      notices)

    def test_arm64_bundle_refuses_x64_and_arm64ec_images(self):
        x64 = build_pe(["KERNEL32.dll", "VCRUNTIME140.dll", "MSVCP140.dll"], dll=True)
        self.swift["layout"]["swiftCore.dll"].update(bytes=len(x64), sha256=hashlib.sha256(x64).hexdigest())
        (self.runtime / "swiftCore.dll").write_bytes(x64)
        with self.assertRaisesRegex(BUILD.BundleError, "swiftCore.dll is not a native arm64 DLL \\(it is x64\\)"):
            self.assemble()
        self.setUp()
        self.microsoft["modules"]["msvcp140.dll"]["bytes"] = build_pe(["vcruntime140.dll"], dll=True,
                                                                      hybrid_metadata=0x18000A2E8)
        with self.assertRaisesRegex(BUILD.BundleError, "msvcp140.dll is not a native arm64 DLL \\(it is arm64ec\\)"):
            self.assemble()
        self.setUp()
        self.application["executables"]["SpeakWindows.exe"] = build_pe(["USER32.dll", "swiftCore.dll"])
        with self.assertRaisesRegex(BUILD.BundleError, "not a Windows ARM64 executable \\(it is x64\\)"):
            self.assemble()

    def test_cpu_only_local_runtime_is_bundled(self):
        root = pathlib.Path(self.directory.name) / "local-arm64"
        local = BUILD.load_local_runtime(root, write_local_runtime(root, graph=LOCAL_ARM64_GRAPH, architecture="arm64"),
                                         "arm64")
        policy = BUILD.Policy.load(local_runtime=[module["name"] for module in local["modules"].values()])
        entries, manifest = self.assemble(policy=policy, local_runtime=local)
        for name in LOCAL_ARM64_GRAPH:
            self.assertIn(name, entries)
        self.assertNotIn("ggml-vulkan.dll", entries)
        self.assertIsNone(manifest["sources"]["localInferenceRuntime"]["vulkanSdk"])
        self.assertEqual(manifest["sources"]["localInferenceRuntime"]["architecture"], "arm64")
        self.assertIn("CPU backend only", entries["THIRD-PARTY-NOTICES.txt"].decode())


if __name__ == "__main__":
    unittest.main()
