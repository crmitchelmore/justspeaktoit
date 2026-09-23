"""Checks that the whisper.cpp pins, vendored headers and adapter agree."""
import hashlib
import importlib.util
import json
import pathlib
import re
import sys
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent
REPOSITORY = HERE.parent.parent
VENDORED = REPOSITORY / "Sources" / "CWindowsSupport" / "whisper-cpp"
sys.dont_write_bytecode = True


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


RUNTIME = load("build_whisper_runtime", HERE / "build-whisper-runtime.py")
BUNDLE_TESTS = load("test_windows_bundle", HERE.parent / "windows-bundle" / "test_windows_bundle.py")


class PinTests(unittest.TestCase):
    def setUp(self):
        self.pins = RUNTIME.load_pins()

    def test_vendored_headers_match_their_recorded_provenance_and_the_runtime_pin(self):
        provenance = (VENDORED / "PROVENANCE.md").read_text(encoding="utf-8")
        whisper = self.pins["whisperCpp"]
        self.assertIn(whisper["commit"], provenance)
        self.assertIn("`" + whisper["tag"] + "`", provenance)
        rows = re.findall(r"\| `([^`]+)` \| `[^`]+` \| `([0-9a-f]{64})` \|", provenance)
        self.assertEqual({name for name, _ in rows},
                         {"whisper.h", "ggml.h", "ggml-cpu.h", "ggml-backend.h", "ggml-alloc.h", "LICENSE"})
        for name, digest in rows:
            self.assertEqual(hashlib.sha256((VENDORED / name).read_bytes()).hexdigest(), digest, name)
        self.assertEqual(dict(rows)["LICENSE"], whisper["licenseSHA256"])

    def test_adapter_refuses_every_version_but_the_pinned_one(self):
        adapter = (REPOSITORY / "Sources" / "CWindowsSupport" / "WindowsWhisper.cpp").read_text(encoding="utf-8")
        self.assertIn('expectedVersion = "%s"' % self.pins["whisperCpp"]["version"], adapter)
        swift = (REPOSITORY / "Sources" / "SpeakWindows" / "WindowsLocalModels.swift").read_text(encoding="utf-8")
        self.assertIn("whisper.cpp " + self.pins["whisperCpp"]["version"], swift)

    def test_build_keeps_vulkan_optional_and_avoids_extra_runtimes(self):
        target = RUNTIME.architecture_pins(self.pins, "x64")
        arguments = target["cmakeArguments"]
        # A tagged release build: whisper_version() is then "1.9.4", not "1.9.4-dev",
        # which the adapter's exact version check requires.
        for required in ["-DWHISPER_BUILD_IS_DEV=OFF", "-DBUILD_SHARED_LIBS=ON", "-DGGML_BACKEND_DL=ON", "-DGGML_CPU_ALL_VARIANTS=ON",
                         "-DGGML_VULKAN=ON", "-DGGML_OPENMP=OFF", "-DGGML_NATIVE=OFF",
                         "-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL"]:
            self.assertIn(required, arguments)
        self.assertEqual(arguments[:4], ["-G", "Visual Studio 17 2022", "-A", "x64"])
        sdk = target["vulkanSdk"]
        self.assertTrue(sdk["url"].startswith("https://sdk.lunarg.com/"))
        self.assertTrue(sdk["url"].endswith("/" + sdk["name"]))
        self.assertEqual(len(sdk["sha256"]), 64)
        self.assertIn("ggml-vulkan.dll", target["requiredModules"])
        self.assertIsNone(target["developerEnvironment"])

    def test_arm64_builds_one_baseline_cpu_backend_with_clang(self):
        x64, arm64 = (RUNTIME.architecture_pins(self.pins, name) for name in ("x64", "arm64"))
        arguments = arm64["cmakeArguments"]
        # ggml refuses MSVC for ARM, and rejects GGML_CPU_ALL_VARIANTS on Windows ARM.
        self.assertEqual(arguments[:2], ["-G", "Ninja Multi-Config"])
        for required in ["-DCMAKE_C_COMPILER=clang", "-DCMAKE_CXX_COMPILER=clang++",
                         "-DCMAKE_C_COMPILER_TARGET=arm64-pc-windows-msvc", "-DCMAKE_CXX_COMPILER_TARGET=arm64-pc-windows-msvc",
                         "-DGGML_CPU_ALL_VARIANTS=OFF", "-DGGML_VULKAN=OFF", "-DGGML_CPU_ARM_ARCH=armv8-a"]:
            self.assertIn(required, arguments)
        # Every other switch, including the release version and shared Visual C++
        # runtime, matches the x64 build.
        specific = {"-DGGML_CPU_ALL_VARIANTS=ON", "-DGGML_VULKAN=ON", "-DGGML_CPU_ALL_VARIANTS=OFF", "-DGGML_VULKAN=OFF",
                    "-DGGML_CPU_ARM_ARCH=armv8-a"}
        shared = [value for value in x64["cmakeArguments"][4:] if value not in specific]
        self.assertEqual([value for value in arguments if value.startswith("-D") and value not in specific
                          and "COMPILER" not in value], shared)
        self.assertIsNone(arm64["vulkanSdk"])
        self.assertEqual(arm64["requiredModules"], ["whisper.dll", "ggml.dll", "ggml-base.dll", "ggml-cpu.dll"])
        self.assertIsNone(arm64["cpuVariantPattern"])
        self.assertIn(arm64["developerEnvironment"], RUNTIME.DEVELOPER_COMPONENTS)
        with self.assertRaisesRegex(RUNTIME.RuntimeError_, "no whisper.cpp runtime is pinned"):
            RUNTIME.architecture_pins(self.pins, "x86")


class ImportPolicyTests(unittest.TestCase):
    def setUp(self):
        self.pins = RUNTIME.load_pins()
        self.policy = RUNTIME.load_policy()

    def test_runtime_may_import_windows_the_visual_cpp_runtime_the_vulkan_loader_and_itself(self):
        data = BUNDLE_TESTS.build_pe(["ggml-base.dll", "vulkan-1.dll", "MSVCP140.dll", "KERNEL32.dll",
                                      "api-ms-win-crt-heap-l1-1-0.dll"], dll=True)
        static, _ = RUNTIME.classify_imports("ggml-vulkan.dll", data, ["ggml-vulkan.dll", "ggml-base.dll"],
                                             self.policy)
        self.assertIn("vulkan-1.dll", static)

    def test_unknown_imports_and_non_dlls_are_refused(self):
        foreign = BUNDLE_TESTS.build_pe(["ggml-base.dll", "vcomp140.dll", "libomp.dll"], dll=True)
        with self.assertRaisesRegex(RUNTIME.RuntimeError_, "libomp.dll"):
            RUNTIME.classify_imports("ggml-cpu-x64.dll", foreign, ["ggml-base.dll"], self.policy)
        executable = BUNDLE_TESTS.build_pe(["KERNEL32.dll"])
        with self.assertRaisesRegex(RUNTIME.RuntimeError_, "not a native x64 DLL"):
            RUNTIME.classify_imports("whisper.dll", executable, [], self.policy)

    def test_each_architecture_accepts_only_its_native_images(self):
        arm64 = BUNDLE_TESTS.PE.IMAGE_FILE_MACHINE_ARM64
        native = {
            "x64": [BUNDLE_TESTS.build_pe(["KERNEL32.dll"], dll=True)],
            "arm64": [BUNDLE_TESTS.build_pe(["KERNEL32.dll"], dll=True, machine=arm64),
                      BUNDLE_TESTS.build_pe(["KERNEL32.dll"], dll=True, machine=arm64, hybrid_metadata=0x180001000)],
        }
        arm64ec = BUNDLE_TESTS.build_pe(["KERNEL32.dll"], dll=True, hybrid_metadata=0x180001000)
        for architecture, images in native.items():
            for data in images:
                RUNTIME.classify_imports("ggml.dll", data, [], self.policy, architecture)
            other = "arm64" if architecture == "x64" else "x64"
            for data in images + [arm64ec]:
                with self.assertRaisesRegex(RUNTIME.RuntimeError_, "not a native %s DLL" % other):
                    RUNTIME.classify_imports("ggml.dll", data, [], self.policy, other)

    def test_collection_requires_every_module_and_enough_cpu_variants(self):
        target = RUNTIME.architecture_pins(self.pins, "x64")
        with tempfile.TemporaryDirectory() as directory:
            binaries = pathlib.Path(directory)
            for name in target["requiredModules"] + ["ggml-cpu-x64.dll", "ggml-cpu-haswell.dll", "unrelated.dll"]:
                (binaries / name).write_bytes(BUNDLE_TESTS.build_pe(["KERNEL32.dll"], dll=True))
            with self.assertRaisesRegex(RUNTIME.RuntimeError_, "too few CPU backend variants"):
                RUNTIME.collect(target, self.policy, binaries)
            for name in ["ggml-cpu-sse42.dll", "ggml-cpu-icelake.dll"]:
                (binaries / name).write_bytes(BUNDLE_TESTS.build_pe(["KERNEL32.dll"], dll=True))
            files = RUNTIME.collect(target, self.policy, binaries)
            self.assertNotIn("unrelated.dll", [row["name"] for row in files])
            self.assertEqual(len(files), len(target["requiredModules"]) + 4)
            self.assertEqual({row["architecture"] for row in files}, {"x64"})
            (binaries / "ggml-vulkan.dll").unlink()
            with self.assertRaisesRegex(RUNTIME.RuntimeError_, "did not produce ggml-vulkan.dll"):
                RUNTIME.collect(target, self.policy, binaries)

    def test_arm64_collection_takes_the_single_cpu_backend(self):
        target = RUNTIME.architecture_pins(self.pins, "arm64")
        arm64 = BUNDLE_TESTS.PE.IMAGE_FILE_MACHINE_ARM64
        with tempfile.TemporaryDirectory() as directory:
            binaries = pathlib.Path(directory)
            for name in target["requiredModules"] + ["ggml-cpu-x64.dll", "unrelated.dll"]:
                (binaries / name).write_bytes(BUNDLE_TESTS.build_pe(["KERNEL32.dll"], dll=True, machine=arm64))
            files = RUNTIME.collect(target, self.policy, binaries, "arm64")
            self.assertEqual([row["name"] for row in files], sorted(target["requiredModules"]))
            self.assertEqual({row["architecture"] for row in files}, {"arm64"})
            # An x64 build of the same file name is refused as the ARM64 runtime.
            (binaries / "ggml-cpu.dll").write_bytes(BUNDLE_TESTS.build_pe(["KERNEL32.dll"], dll=True))
            with self.assertRaisesRegex(RUNTIME.RuntimeError_, "ggml-cpu.dll is not a native arm64 DLL"):
                RUNTIME.collect(target, self.policy, binaries, "arm64")
            (binaries / "ggml-cpu.dll").unlink()
            with self.assertRaisesRegex(RUNTIME.RuntimeError_, "did not produce ggml-cpu.dll"):
                RUNTIME.collect(target, self.policy, binaries, "arm64")


class DeveloperEnvironmentTests(unittest.TestCase):
    def test_set_output_is_parsed_without_pseudo_variables(self):
        text = "\n".join(["ALLUSERSPROFILE=C:\\ProgramData", "Path=C:\\VS\\bin\\HostARM64\\ARM64;C:\\Windows",
                          "VSCMD_ARG_TGT_ARCH=arm64", "=C:=C:\\work", "not a variable", "EMPTY=", "A=B=C"])
        self.assertEqual(RUNTIME.parse_environment(text), {
            "ALLUSERSPROFILE": "C:\\ProgramData", "Path": "C:\\VS\\bin\\HostARM64\\ARM64;C:\\Windows",
            "VSCMD_ARG_TGT_ARCH": "arm64", "EMPTY": "", "A": "B=C"})

    def test_architectures_without_a_developer_environment_keep_the_base_environment(self):
        base = {"PATH": "C:\\Windows"}
        environment = RUNTIME.developer_environment(None, base)
        self.assertEqual(environment, base)
        self.assertIsNot(environment, base)
        with self.assertRaisesRegex(RUNTIME.RuntimeError_, "unknown developer environment"):
            RUNTIME.developer_environment("x86", base)


if __name__ == "__main__":
    unittest.main()
