#!/usr/bin/env python3
"""The pinned local Whisper runtime the Windows bundle admits."""
import pathlib
import sys
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))
from bundle_test_fixtures import (  # noqa: E402
    BUILD,
    CLOSURE_GRAPH,
    LOCAL_ARM64_GRAPH,
    LOCAL_GRAPH,
    LOCAL_PINS,
    PE,
    write_local_runtime,
)


class LocalRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = pathlib.Path(self.directory.name)

    def test_authenticated_runtime_lists_every_pinned_module(self):
        pins = write_local_runtime(self.root)
        runtime = BUILD.load_local_runtime(self.root, pins)
        self.assertEqual(sorted(runtime["modules"]), sorted(name.lower() for name in LOCAL_GRAPH))
        self.assertEqual(runtime["modules"]["whisper.dll"]["provenance"]["commit"], LOCAL_PINS["whisperCpp"]["commit"])

    def test_tampered_or_unpinned_runtime_is_refused(self):
        pins = write_local_runtime(self.root)
        dll = self.root / "runtime" / "ggml.dll"
        dll.write_bytes(dll.read_bytes()[:-1] + b"X")
        with self.assertRaisesRegex(BUILD.BundleError, "does not match its manifest"):
            BUILD.load_local_runtime(self.root, pins)
        for key, value in [("commit", "0" * 40), ("cmakeArguments", ["-DGGML_VULKAN=OFF"])]:
            with tempfile.TemporaryDirectory() as other:
                pins = write_local_runtime(pathlib.Path(other), **{key: value})
                with self.assertRaisesRegex(BUILD.BundleError, "manifest " + key):
                    BUILD.load_local_runtime(pathlib.Path(other), pins)
        with tempfile.TemporaryDirectory() as other:
            graph = dict(LOCAL_GRAPH, **{"extra.dll": (["KERNEL32.dll"], [])})
            pins = write_local_runtime(pathlib.Path(other), graph=graph)
            with self.assertRaisesRegex(BUILD.BundleError, "unexpected local runtime file"):
                BUILD.load_local_runtime(pathlib.Path(other), pins)
        with tempfile.TemporaryDirectory() as other:
            graph = {name: value for name, value in LOCAL_GRAPH.items() if name != "ggml-vulkan.dll"}
            pins = write_local_runtime(pathlib.Path(other), graph=graph)
            with self.assertRaisesRegex(BUILD.BundleError, "incomplete: ggml-vulkan.dll"):
                BUILD.load_local_runtime(pathlib.Path(other), pins)

    def test_arm64_runtime_is_one_native_cpu_backend_without_vulkan(self):
        pins = write_local_runtime(self.root, graph=LOCAL_ARM64_GRAPH, architecture="arm64")
        runtime = BUILD.load_local_runtime(self.root, pins, "arm64")
        self.assertEqual(sorted(runtime["modules"]), sorted(LOCAL_ARM64_GRAPH))
        self.assertIsNone(runtime["modules"]["ggml-cpu.dll"]["provenance"]["vulkanSdk"])
        self.assertIsNone(runtime["manifest"]["vulkanSdk"])
        target = LOCAL_PINS["architectures"]["arm64"]
        self.assertIn("-DGGML_CPU_ALL_VARIANTS=OFF", target["cmakeArguments"])
        self.assertIn("-DGGML_VULKAN=OFF", target["cmakeArguments"])
        # The same manifest cannot stand in for the other architecture.
        with self.assertRaisesRegex(BUILD.BundleError, "manifest architecture"):
            BUILD.load_local_runtime(self.root, pins, "x64")

    def test_arm64_runtime_refuses_foreign_images_and_other_backends(self):
        cases = [
            ({"machine": PE.IMAGE_FILE_MACHINE_AMD64}, LOCAL_ARM64_GRAPH, "not a native arm64 DLL"),
            ({}, {name: value for name, value in LOCAL_ARM64_GRAPH.items() if name != "ggml-cpu.dll"},
             "incomplete: ggml-cpu.dll"),
            ({}, dict(LOCAL_ARM64_GRAPH, **{"ggml-vulkan.dll": LOCAL_GRAPH["ggml-vulkan.dll"]}),
             "unexpected local runtime file"),
            ({}, dict(LOCAL_ARM64_GRAPH, **{"ggml-cpu-armv8.2_1.dll": (["ggml-base.dll"], [])}),
             "unexpected local runtime file"),
        ]
        for overrides, graph, message in cases:
            with tempfile.TemporaryDirectory() as other:
                pins = write_local_runtime(pathlib.Path(other), graph=graph, architecture="arm64", **overrides)
                with self.assertRaisesRegex(BUILD.BundleError, message):
                    BUILD.load_local_runtime(pathlib.Path(other), pins, "arm64")
        with self.assertRaisesRegex(BUILD.BundleError, "no whisper.cpp runtime is pinned for x86"):
            BUILD.load_local_runtime(self.root, write_local_runtime(self.root), "x86")

    def test_run_time_loaded_imports_are_not_expected_in_ordinary_runs(self):
        policy = BUILD.Policy.load(local_runtime=list(LOCAL_GRAPH))
        graph = dict(CLOSURE_GRAPH, **LOCAL_GRAPH, **{"concrt140.dll": (["KERNEL32.dll"], [])})

        def read(name, category):
            return graph[name]
        closure = BUILD.resolve_closure("SpeakWindows.exe", read, policy, sorted(LOCAL_GRAPH))
        whisper = closure["bundled"]["whisper.dll"]
        self.assertEqual(whisper["source"], BUILD.LOCAL_RUNTIME)
        self.assertEqual(whisper["importedBy"], [{"importer": "SpeakWindows.exe", "kind": "runtime-loaded"}])
        self.assertTrue(all(reference["kind"].startswith("runtime-")
                            for reference in closure["bundled"]["concrt140.dll"]["importedBy"]))
        self.assertIn({"importer": "SpeakWindows.exe", "kind": "static"}, closure["bundled"]["msvcp140.dll"]["importedBy"])
        self.assertIn("vulkan-1.dll", closure["system"])
        with self.assertRaisesRegex(BUILD.BundleError, "not part of the local runtime"):
            BUILD.resolve_closure("SpeakWindows.exe", read, policy, ["swiftCore.dll"])
        with self.assertRaisesRegex(BUILD.BundleError, "more than one category"):
            BUILD.Policy.load(local_runtime=["kernel32.dll"])


if __name__ == "__main__":
    unittest.main()
