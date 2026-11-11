#!/usr/bin/env python3
"""PE reading, the dependency closure and path safety of the Windows bundle tooling."""
import pathlib
import re
import struct
import sys
import unittest

HERE = pathlib.Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))
from bundle_test_fixtures import BUILD, CLOSURE_GRAPH, PE, build_pe  # noqa: E402
from pe_test_fixtures import version_block  # noqa: E402


class PEReaderTests(unittest.TestCase):
    def test_static_and_delay_imports_are_read_in_table_order(self):
        image = PE.PEImage(build_pe(["KERNEL32.dll", "swiftCore.dll"], ["Foundation.dll", "WINHTTP.dll"]))
        self.assertTrue(image.is_x64)
        self.assertFalse(image.is_dll)
        self.assertEqual(image.imports(), ["KERNEL32.dll", "swiftCore.dll"])
        self.assertEqual(image.delay_imports(), ["Foundation.dll", "WINHTTP.dll"])

    def test_legacy_delay_descriptors_use_virtual_addresses(self):
        image = PE.PEImage(build_pe(["KERNEL32.dll"], ["dbghelp.dll"], legacy_delay=True, image_base=0x400000))
        self.assertEqual(image.delay_imports(), ["dbghelp.dll"])
        # A legacy descriptor whose stored address is below the image base cannot be translated.
        data = bytearray(build_pe(["KERNEL32.dll"], ["dbghelp.dll"], legacy_delay=True, image_base=0x400000))
        struct.pack_into("<I", data, 0x400 + 40 + 4, 0x1000)
        with self.assertRaisesRegex(PE.PEFormatError, "below the image base"):
            PE.PEImage(bytes(data)).delay_imports()

    def test_import_directories_must_contain_complete_descriptors_and_terminator(self):
        for directory, method, width in [(1, "imports", 20), (13, "delay_imports", 32)]:
            for invalid_size in [1, width]:
                data = bytearray(build_pe(["KERNEL32.dll"], ["Foundation.dll"]))
                struct.pack_into("<I", data, 0x40 + 24 + 112 + directory * 8 + 4, invalid_size)
                with self.assertRaises(PE.PEFormatError):
                    getattr(PE.PEImage(data), method)()

    def test_descriptor_may_not_cross_mapped_section_boundary(self):
        data = bytearray(build_pe(["KERNEL32.dll"]))
        # Raw section ends 19 bytes into the descriptor, although file bytes remain.
        struct.pack_into("<I", data, 0x40 + 24 + 240 + 16, 19)
        with self.assertRaises(PE.PEFormatError):
            PE.PEImage(data).imports()

    def test_optional_and_version_lengths_are_checked(self):
        with self.assertRaises(PE.PEFormatError):
            PE.PEImage(build_pe()[:0x40 + 24 + 120])
        block = bytearray(version_block((1, 2, 3, 4), {}))
        struct.pack_into("<H", block, 0, len(block) + 1)
        with self.assertRaises(PE.PEFormatError):
            PE.parse_version_block(block)

    def test_dll_flag_and_foreign_machine_are_reported(self):
        image = PE.PEImage(build_pe(dll=True, machine=0x14C))
        self.assertTrue(image.is_dll)
        self.assertFalse(image.is_x64)

    def test_hybrid_metadata_separates_arm64ec_and_arm64x_from_native_images(self):
        arm64 = PE.IMAGE_FILE_MACHINE_ARM64
        cases = [
            (build_pe(), PE.X64, {"x64"}),
            (build_pe(machine=arm64), PE.ARM64, {"arm64"}),
            # ARM64EC keeps an x64 header: plain x64 code cannot use it and a
            # native ARM64 process cannot load it.
            (build_pe(hybrid_metadata=0x18000A2E8), PE.ARM64EC, set()),
            (build_pe(machine=arm64, hybrid_metadata=0x1800325E8), PE.ARM64X, {"arm64"}),
            # A zero pointer, or a load configuration too short to hold it, is not hybrid.
            (build_pe(hybrid_metadata=0), PE.X64, {"x64"}),
            (build_pe(machine=arm64, hybrid_metadata=0x1800325E8, load_config_size=0x40), PE.ARM64, {"arm64"}),
        ]
        for data, architecture, native in cases:
            image = PE.PEImage(data)
            self.assertEqual(image.architecture, architecture)
            self.assertEqual(image.is_x64, architecture == PE.X64)
            self.assertEqual({target for target in ("x64", "arm64") if image.runs_natively_on(target)}, native)
        self.assertEqual(PE.PEImage(build_pe(machine=0x1C4)).architecture, "machine-0x01c4")
        with self.assertRaises(ValueError):
            PE.PEImage(build_pe()).runs_natively_on("x86")

    def test_truncated_load_configuration_is_rejected(self):
        data = bytearray(build_pe(machine=PE.IMAGE_FILE_MACHINE_ARM64, hybrid_metadata=0x180001000))
        struct.pack_into("<I", data, 0x40 + 24 + 112 + PE.DIRECTORY_LOAD_CONFIG * 8 + 4, 2)
        with self.assertRaisesRegex(PE.PEFormatError, "load configuration"):
            PE.PEImage(bytes(data)).architecture

    def test_version_resource_is_decoded(self):
        image = PE.PEImage(build_pe(version=((14, 51, 36247, 0), {"OriginalFilename": "vcruntime140.dll",
                                                                    "CompanyName": "Microsoft Corporation"})))
        info = image.version_info()
        self.assertEqual(info["fileVersion"], "14.51.36247.0")
        self.assertEqual(info["strings"]["OriginalFilename"], "vcruntime140.dll")
        self.assertIsNone(PE.PEImage(build_pe()).version_info())

    def test_truncated_and_non_pe_input_raise_format_errors(self):
        data = build_pe(["KERNEL32.dll"])
        with self.assertRaises(PE.PEFormatError):
            PE.PEImage(data[:0x300])
        with self.assertRaises(PE.PEFormatError):
            PE.PEImage(b"not a pe file" * 100)
        broken = bytearray(data)
        struct.pack_into("<I", broken, 0x3C, 0x7FFFFFF0)
        with self.assertRaises(PE.PEFormatError):
            PE.PEImage(bytes(broken))

    def test_import_name_outside_the_image_is_rejected(self):
        data = bytearray(build_pe(["KERNEL32.dll"]))
        struct.pack_into("<I", data, 0x400 + 12, 0x9000)
        with self.assertRaisesRegex(PE.PEFormatError, "outside every section"):
            PE.PEImage(bytes(data)).imports()


class ClosureTests(unittest.TestCase):
    GRAPH = CLOSURE_GRAPH

    def setUp(self):
        self.policy = BUILD.Policy.load()

    def read(self, graph):
        def read_imports(name, category):
            self.assertIn(category, ("application", BUILD.SWIFT_RUNTIME, BUILD.MICROSOFT_RUNTIME))
            return graph[name]
        return read_imports

    def test_windows_support_link_libraries_are_allowed_system_modules(self):
        # Import libraries the native target links become PE imports; the bundle refuses unknown ones.
        package = (HERE.parents[1] / "Package.swift").read_text(encoding="utf-8")
        target = package[package.index('name: "CWindowsSupport"'):]
        target = target[:target.index(".target(")] if ".target(" in target else target
        static_only = {"uuid", "mfuuid"}
        linked = set(re.findall(r'linkedLibrary\("(\w+)"', target)) - static_only
        self.assertTrue(linked)
        for library in sorted(linked):
            self.assertIn(library.lower() + ".dll", self.policy.system, library)

    def test_closure_includes_delay_and_transitive_dependencies_once(self):
        closure = BUILD.resolve_closure("SpeakWindows.exe", self.read(self.GRAPH), self.policy)
        self.assertEqual(list(closure["bundled"]), ["_foundationicu.dll", "foundation.dll", "foundationnetworking.dll",
                                                    "msvcp140.dll", "swiftcore.dll", "vcruntime140.dll"])
        self.assertEqual(closure["bundled"]["msvcp140.dll"]["name"], "msvcp140.dll")
        self.assertEqual(closure["bundled"]["foundation.dll"]["importedBy"],
                         [{"importer": "SpeakWindows.exe", "kind": "delay"},
                          {"importer": "FoundationNetworking.dll", "kind": "static"}])
        self.assertEqual({entry["source"] for entry in closure["bundled"].values()},
                         {BUILD.SWIFT_RUNTIME, BUILD.MICROSOFT_RUNTIME})
        self.assertEqual(list(closure["system"]), ["api-ms-win-crt-heap-l1-1-0.dll", "api-ms-win-crt-runtime-l1-1-0.dll",
                                                   "crypt32.dll", "kernel32.dll", "user32.dll"])
        self.assertEqual([entry["importer"] for entry in closure["system"]["kernel32.dll"]["importedBy"]],
                         ["swiftCore.dll", "vcruntime140.dll", "_FoundationICU.dll"])

    def test_unknown_non_system_module_is_refused_with_its_importer(self):
        graph = dict(self.GRAPH)
        graph["swiftCore.dll"] = (["KERNEL32.dll", "libcurl.dll"], [])
        with self.assertRaisesRegex(BUILD.BundleError, "swiftCore.dll imports libcurl.dll"):
            BUILD.resolve_closure("SpeakWindows.exe", self.read(graph), self.policy)

    def test_multiple_roots_keep_shared_cli_only_and_delay_import_attribution(self):
        graph = dict(self.GRAPH, **{
            "speak.exe": (["swiftCore.dll", "swiftWinSDK.dll"], ["Foundation.dll"]),
            "swiftWinSDK.dll": (["swiftCore.dll"], []),
        })
        closure = BUILD.resolve_closure(BUILD.EXECUTABLES, self.read(graph), self.policy)
        self.assertEqual(closure["bundled"]["swiftwinsdk.dll"]["importedBy"],
                         [{"importer": "speak.exe", "kind": "static"}])
        self.assertIn({"importer": "speak.exe", "kind": "static"},
                      closure["bundled"]["swiftcore.dll"]["importedBy"])
        self.assertIn({"importer": "speak.exe", "kind": "delay"},
                      closure["bundled"]["foundation.dll"]["importedBy"])
        self.assertNotIn("swiftWinSDK.dll", closure["roots"]["SpeakWindows.exe"]["staticModules"])
        self.assertIn("swiftWinSDK.dll", closure["roots"]["speak.exe"]["staticModules"])
        for root in BUILD.EXECUTABLES:
            self.assertNotIn("FoundationNetworking.dll", closure["roots"][root]["staticModules"])
            self.assertNotIn("Foundation.dll", closure["roots"][root]["staticModules"])
            self.assertIn("vcruntime140.dll", closure["roots"][root]["staticModules"])

    def test_cli_root_unknown_and_transitive_test_imports_are_refused(self):
        for imports in (["libcurl.dll"], ["Testing.dll"]):
            graph = dict(self.GRAPH, **{"speak.exe": ([], ["swiftWinSDK.dll"]),
                                      "swiftWinSDK.dll": (imports, [])})
            with self.assertRaisesRegex(BUILD.BundleError, "swiftWinSDK.dll imports"):
                BUILD.resolve_closure(BUILD.EXECUTABLES, self.read(graph), self.policy)

    def test_empty_and_duplicate_roots_are_refused(self):
        for roots in ([], ["speak.exe", "Speak.EXE"]):
            with self.assertRaisesRegex(BUILD.BundleError, "distinct"):
                BUILD.resolve_closure(roots, self.read({}), self.policy)

    def test_test_library_import_is_refused_even_transitively(self):
        graph = dict(self.GRAPH)
        graph["Foundation.dll"] = (["swiftCore.dll"], ["XCTest.dll"])
        with self.assertRaisesRegex(BUILD.BundleError, "test library XCTest.dll"):
            BUILD.resolve_closure("SpeakWindows.exe", self.read(graph), self.policy)

    def test_additional_runtime_modules_are_bundled_and_traversed(self):
        policy = BUILD.Policy(dict(self.policy.data, additionalRuntimeModules=["swiftSwiftOnoneSupport.dll"]))
        graph = dict(self.GRAPH, **{"swiftSwiftOnoneSupport.dll": (["swiftCore.dll", "swiftWinSDK.dll"], []),
                                    "swiftWinSDK.dll": (["swiftCore.dll"], [])})
        closure = BUILD.resolve_closure("SpeakWindows.exe", self.read(graph), policy)
        self.assertIn("swiftwinsdk.dll", closure["bundled"])
        self.assertEqual(closure["bundled"]["swiftswiftononesupport.dll"]["importedBy"][0]["kind"], "runtime-loaded")

    def test_policy_rejects_overlapping_categories_and_unknown_additions(self):
        with self.assertRaisesRegex(BUILD.BundleError, "more than one category"):
            BUILD.Policy(dict(self.policy.data, windowsSystemModules=["kernel32.dll", "swiftCore.dll"]))
        with self.assertRaisesRegex(BUILD.BundleError, "additionalRuntimeModules"):
            BUILD.Policy(dict(self.policy.data, additionalRuntimeModules=["kernel32.dll"]))

    def test_policy_classification_and_forbidden_patterns(self):
        policy = self.policy
        self.assertEqual(policy.classify("API-MS-WIN-CORE-SYNCH-L1-2-0.dll"), BUILD.SYSTEM_MODULE)
        self.assertEqual(policy.classify("ucrtbase.dll"), BUILD.SYSTEM_MODULE)
        self.assertEqual(policy.classify("api-ms-win-crt-private-l1-1-0.dll"), BUILD.SYSTEM_MODULE)
        # GetDpiForMonitor links through the shcore scaling API set; no other shcore set is admitted.
        self.assertEqual(policy.classify("api-ms-win-shcore-scaling-l1-1-1.dll"), BUILD.SYSTEM_MODULE)
        self.assertEqual(policy.classify("api-ms-win-shcore-stream-l1-1-0.dll"), BUILD.UNKNOWN_MODULE)
        self.assertEqual(policy.classify("ext-ms-win-something-l1-1-0.dll"), BUILD.UNKNOWN_MODULE)
        self.assertEqual(policy.classify("Testing.dll"), BUILD.TEST_MODULE)
        for path in ["swiftCore.lib", "usr/include/module.modulemap", "SpeakAppPackageTests.exe", "XCTest.dll",
                     "SpeakApp_SpeakWindowsPlatformTests.resources/Fixtures/tone.m4a", "plutil.exe", "app.pdb",
                     "lib/swift/windows/Foundation.swiftmodule", "rtl.msi"]:
            self.assertTrue(policy.forbids(path), path)
        for path in ["SpeakWindows.exe", "swiftCore.dll", "SpeakApp_SpeakCore.resources/Info.plist",
                     "bundle-manifest.json", "licenses/LICENSE-swift.txt"]:
            self.assertFalse(policy.forbids(path), path)


class PathSafetyTests(unittest.TestCase):
    def test_unsafe_components_are_rejected(self):
        for path in ["../x.dll", "a/../b", "/abs", "a\\b", "C:/x", "", "con", "CON.dll", "nul.txt", "com1.dll",
                     "a./b", " a", "a ", "tab\there", "a<.txt", "a>.txt", 'a".txt',
                     "a|.txt", "a?.txt", "a*.txt", "dir/bad?.txt"]:
            with self.assertRaises(BUILD.BundleError, msg=path):
                BUILD.check_bundle_path(path)
        self.assertEqual(BUILD.check_bundle_path("SpeakApp_SpeakCore.resources/Info.plist"),
                         "SpeakApp_SpeakCore.resources/Info.plist")

    def test_output_separation_rejects_equal_and_nested_paths(self):
        app, cache = pathlib.Path("/app"), pathlib.Path("/cache")
        for output in [app, cache, app / "bundle", cache / "bundle", pathlib.Path("/")]:
            with self.assertRaises(BUILD.BundleError):
                BUILD.check_output_separation(app, cache, output)
        BUILD.check_output_separation(app, cache, pathlib.Path("/bundle"))

    def test_layout_rejects_case_collisions_forbidden_files_and_file_directory_clashes(self):
        policy = BUILD.Policy.load()
        with self.assertRaisesRegex(BUILD.BundleError, "case-insensitive"):
            BUILD.check_bundle_layout(["Foundation.dll", "foundation.DLL"], policy)
        with self.assertRaisesRegex(BUILD.BundleError, "forbids"):
            BUILD.check_bundle_layout(["SpeakWindows.exe", "swiftCore.lib"], policy)
        with self.assertRaisesRegex(BUILD.BundleError, "share a name"):
            BUILD.check_bundle_layout(["licenses", "licenses/LICENSE-swift.txt"], policy)
        BUILD.check_bundle_layout(["SpeakWindows.exe", "licenses/LICENSE-swift.txt", "swiftCore.dll"], policy)


if __name__ == "__main__":
    unittest.main()
