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
        arguments = self.pins["cmakeArguments"]
        for required in ["-DBUILD_SHARED_LIBS=ON", "-DGGML_BACKEND_DL=ON", "-DGGML_CPU_ALL_VARIANTS=ON",
                         "-DGGML_VULKAN=ON", "-DGGML_OPENMP=OFF", "-DGGML_NATIVE=OFF",
                         "-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL"]:
            self.assertIn(required, arguments)
        sdk = self.pins["vulkanSdk"]
        self.assertTrue(sdk["url"].startswith("https://sdk.lunarg.com/"))
        self.assertTrue(sdk["url"].endswith("/" + sdk["name"]))
        self.assertEqual(len(sdk["sha256"]), 64)
        self.assertIn("ggml-vulkan.dll", self.pins["requiredModules"])


class ImportPolicyTests(unittest.TestCase):
    def setUp(self):
        self.pins = RUNTIME.load_pins()
        self.policy = RUNTIME.load_policy()

    def test_runtime_may_import_windows_the_visual_cpp_runtime_the_vulkan_loader_and_itself(self):
        data = BUNDLE_TESTS.build_pe(["ggml-base.dll", "vulkan-1.dll", "MSVCP140.dll", "KERNEL32.dll",
                                      "api-ms-win-crt-heap-l1-1-0.dll"], dll=True)
        static, _ = RUNTIME.classify_imports("ggml-vulkan.dll", data, ["ggml-vulkan.dll", "ggml-base.dll"],
                                             self.pins, self.policy)
        self.assertIn("vulkan-1.dll", static)

    def test_unknown_imports_and_non_dlls_are_refused(self):
        foreign = BUNDLE_TESTS.build_pe(["ggml-base.dll", "vcomp140.dll", "libomp.dll"], dll=True)
        with self.assertRaisesRegex(RUNTIME.RuntimeError_, "libomp.dll"):
            RUNTIME.classify_imports("ggml-cpu-x64.dll", foreign, ["ggml-base.dll"], self.pins, self.policy)
        executable = BUNDLE_TESTS.build_pe(["KERNEL32.dll"])
        with self.assertRaisesRegex(RUNTIME.RuntimeError_, "not an x64 DLL"):
            RUNTIME.classify_imports("whisper.dll", executable, [], self.pins, self.policy)

    def test_collection_requires_every_module_and_enough_cpu_variants(self):
        with tempfile.TemporaryDirectory() as directory:
            binaries = pathlib.Path(directory)
            for name in self.pins["requiredModules"] + ["ggml-cpu-x64.dll", "ggml-cpu-haswell.dll", "unrelated.dll"]:
                (binaries / name).write_bytes(BUNDLE_TESTS.build_pe(["KERNEL32.dll"], dll=True))
            with self.assertRaisesRegex(RUNTIME.RuntimeError_, "too few CPU backend variants"):
                RUNTIME.collect(self.pins, self.policy, binaries)
            for name in ["ggml-cpu-sse42.dll", "ggml-cpu-icelake.dll"]:
                (binaries / name).write_bytes(BUNDLE_TESTS.build_pe(["KERNEL32.dll"], dll=True))
            files = RUNTIME.collect(self.pins, self.policy, binaries)
            self.assertNotIn("unrelated.dll", [row["name"] for row in files])
            self.assertEqual(len(files), len(self.pins["requiredModules"]) + 4)
            (binaries / "ggml-vulkan.dll").unlink()
            with self.assertRaisesRegex(RUNTIME.RuntimeError_, "did not produce ggml-vulkan.dll"):
                RUNTIME.collect(self.pins, self.policy, binaries)


if __name__ == "__main__":
    unittest.main()
