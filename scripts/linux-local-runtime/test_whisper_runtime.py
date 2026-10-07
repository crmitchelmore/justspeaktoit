"""Checks that the Linux whisper.cpp runtime pins, loader and builder agree."""
import importlib.util
import pathlib
import re
import sys
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent
REPOSITORY = HERE.parent.parent
sys.dont_write_bytecode = True


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


RUNTIME = load("build_whisper_runtime_linux", HERE / "build-whisper-runtime.py")
LOADER = (REPOSITORY / "Sources" / "CLinuxSupport" / "LinuxWhisper.c").read_text(encoding="utf-8")

SAMPLE_READELF = """ELF Header:
  Class:                             ELF64
  Type:                              DYN (Shared object file)
  Machine:                           Advanced Micro Devices X86-64

Dynamic section at offset 0x9ad48 contains 30 entries:
  Tag        Type                         Name/Value
 0x0000000000000001 (NEEDED)             Shared library: [libggml.so.0]
 0x0000000000000001 (NEEDED)             Shared library: [libggml-base.so.0]
 0x0000000000000001 (NEEDED)             Shared library: [libstdc++.so.6]
 0x0000000000000001 (NEEDED)             Shared library: [libc.so.6]
 0x000000000000000e (SONAME)             Library soname: [libwhisper.so.1]
"""


class PinTests(unittest.TestCase):
    def setUp(self):
        self.pins = RUNTIME.load_pins()
        self.target = RUNTIME.architecture_pins(self.pins, "x86_64")

    def test_whisper_pin_is_the_windows_pin_not_a_copy(self):
        self.assertEqual(self.pins["whisperCppPin"], "scripts/windows-local-runtime/dependencies.json")
        self.assertNotIn("whisperCpp", self.pins, "The Linux pins must not carry a second whisper.cpp pin")
        windows = RUNTIME.WINDOWS.load_pins()["whisperCpp"]
        self.assertEqual(RUNTIME.whisper_pin(self.pins), windows)
        self.assertEqual(len(windows["commit"]), 40)

    def test_loader_refuses_every_version_but_the_pinned_one_and_opens_the_pinned_modules(self):
        version = RUNTIME.whisper_pin(self.pins)["version"]
        expected = re.search(r'#define EXPECTED_VERSION "([^"]*)"', LOADER).group(1)
        self.assertEqual(expected, version, "LinuxWhisper.c must refuse every whisper.cpp but the pinned one")
        names = re.search(r"runtime_libraries\[\] = \{([^}]*)\}", LOADER).group(1)
        self.assertEqual(re.findall(r'"([^"]+)"', names), self.target["requiredModules"],
                         "The loader opens the pinned modules, in dependency order")
        self.assertEqual(re.search(r'#define VULKAN_BACKEND "([^"]*)"', LOADER).group(1), self.pins["vulkan"]["module"])
        self.assertTrue('#include "../CWindowsSupport/whisper-cpp/whisper.h"' in LOADER, "One vendored copy of the headers")
        self.assertFalse("ggml_backend_load_all" in LOADER, "ggml's loader would also honour GGML_BACKEND_PATH")
        swift = (REPOSITORY / "Sources" / "SpeakLinux" / "LinuxLocalModels.swift").read_text(encoding="utf-8")
        self.assertIn("whisper.cpp " + version, swift)

    def test_build_is_a_tagged_shared_cpu_build_without_search_paths(self):
        arguments = RUNTIME.cmake_arguments(self.pins, self.target, vulkan=False)
        # whisper_version() is "1.9.4", not "1.9.4-dev", only in a tagged build.
        for required in ["-DWHISPER_BUILD_IS_DEV=OFF", "-DBUILD_SHARED_LIBS=ON", "-DCMAKE_SKIP_RPATH=ON",
                         "-DGGML_BACKEND_DL=ON", "-DGGML_CPU_ALL_VARIANTS=ON", "-DGGML_NATIVE=OFF",
                         "-DGGML_OPENMP=OFF", "-DGGML_VULKAN=OFF", "-DCMAKE_BUILD_TYPE=Release"]:
            self.assertIn(required, arguments)
        windows = RUNTIME.architecture_pins(RUNTIME.WINDOWS.load_pins(), "x64")["cmakeArguments"]
        for shared in ["-DWHISPER_BUILD_IS_DEV=OFF", "-DGGML_BACKEND_DL=ON", "-DGGML_CPU_ALL_VARIANTS=ON",
                       "-DGGML_OPENMP=OFF", "-DGGML_NATIVE=OFF"]:
            self.assertIn(shared, windows, "Linux and Windows x64 agree on " + shared)
        self.assertEqual(RUNTIME.expected_modules(self.pins, self.target, vulkan=False),
                         ["libggml-base.so.0", "libggml.so.0", "libwhisper.so.1"])

    def test_vulkan_is_opt_in_and_admits_only_the_system_loader(self):
        arguments = RUNTIME.cmake_arguments(self.pins, self.target, vulkan=True)
        self.assertIn("-DGGML_VULKAN=ON", arguments)
        self.assertNotIn("-DGGML_VULKAN=OFF", arguments)
        self.assertEqual(RUNTIME.expected_modules(self.pins, self.target, vulkan=True)[-1], "libggml-vulkan.so")
        self.assertIn("libvulkan.so.1", RUNTIME.allowed_system_libraries(self.pins, self.target, vulkan=True))
        self.assertNotIn("libvulkan.so.1", RUNTIME.allowed_system_libraries(self.pins, self.target, vulkan=False))
        with self.assertRaisesRegex(RUNTIME.RuntimeError_, "no Linux whisper.cpp runtime is pinned"):
            RUNTIME.architecture_pins(self.pins, "riscv64")


class LibraryPolicyTests(unittest.TestCase):
    def setUp(self):
        self.pins = RUNTIME.load_pins()
        self.target = RUNTIME.architecture_pins(self.pins, "x86_64")
        self.system = RUNTIME.allowed_system_libraries(self.pins, self.target, vulkan=False)
        self.runtime = set(self.target["requiredModules"])

    def check(self, text, name="libwhisper.so.1"):
        return RUNTIME.check_library(name, RUNTIME.parse_readelf(text), self.target, self.runtime, self.system)

    def test_readelf_output_is_parsed(self):
        elf = RUNTIME.parse_readelf(SAMPLE_READELF)
        self.assertEqual(elf["type"], "DYN")
        self.assertEqual(elf["machine"], "Advanced Micro Devices X86-64")
        self.assertEqual(elf["soname"], "libwhisper.so.1")
        self.assertEqual(elf["needed"], ["libggml.so.0", "libggml-base.so.0", "libstdc++.so.6", "libc.so.6"])
        self.assertEqual(elf["searchPaths"], [])
        self.assertEqual(self.check(SAMPLE_READELF)[0], "libggml.so.0")

    def test_search_paths_foreign_libraries_and_wrong_images_are_refused(self):
        with self.assertRaisesRegex(RUNTIME.RuntimeError_, "search path"):
            self.check(SAMPLE_READELF + " 0x1d (RUNPATH)            Library runpath: [$ORIGIN]\n")
        with self.assertRaisesRegex(RUNTIME.RuntimeError_, "search path"):
            self.check(SAMPLE_READELF + " 0x0f (RPATH)              Library rpath: [/build/bin]\n")
        with self.assertRaisesRegex(RUNTIME.RuntimeError_, "libgomp.so.1"):
            self.check(SAMPLE_READELF + " 0x01 (NEEDED)             Shared library: [libgomp.so.1]\n")
        with self.assertRaisesRegex(RUNTIME.RuntimeError_, "libvulkan.so.1"):
            self.check(SAMPLE_READELF + " 0x01 (NEEDED)             Shared library: [libvulkan.so.1]\n")
        with self.assertRaisesRegex(RUNTIME.RuntimeError_, "is not a Advanced Micro Devices X86-64"):
            self.check(SAMPLE_READELF.replace("Advanced Micro Devices X86-64", "AArch64"))
        with self.assertRaisesRegex(RUNTIME.RuntimeError_, "shared object"):
            self.check(SAMPLE_READELF.replace("DYN (Shared object file)", "EXEC (Executable file)"))
        with self.assertRaisesRegex(RUNTIME.RuntimeError_, "names itself"):
            self.check(SAMPLE_READELF, name="libggml.so.0")

    def test_collection_requires_every_module_and_enough_cpu_variants(self):
        clean = RUNTIME.parse_readelf(SAMPLE_READELF.replace("  0x000000000000000e (SONAME)", "  x"))
        clean["soname"] = None
        with tempfile.TemporaryDirectory() as directory:
            binaries = pathlib.Path(directory)
            for name in ["libggml-base.so.0", "libggml.so.0"]:
                (binaries / name).write_bytes(b"\x7fELF")
            with self.assertRaisesRegex(RUNTIME.RuntimeError_, "libwhisper.so.1"):
                RUNTIME.collect(self.pins, self.target, binaries, False, inspect=lambda path: clean)
            (binaries / "libwhisper.so.1.9.4").write_bytes(b"\x7fELF whisper")
            (binaries / "libwhisper.so.1").symlink_to("libwhisper.so.1.9.4")
            for variant in ["x64", "sse42", "haswell"]:
                (binaries / ("libggml-cpu-%s.so" % variant)).write_bytes(b"\x7fELF")
            with self.assertRaisesRegex(RUNTIME.RuntimeError_, "too few CPU backend variants"):
                RUNTIME.collect(self.pins, self.target, binaries, False, inspect=lambda path: clean)
            for variant in ["sandybridge", "skylakex", "icelake", "zen4", "alderlake"]:
                (binaries / ("libggml-cpu-%s.so" % variant)).write_bytes(b"\x7fELF")
            (binaries / "libparakeet.so.1").write_bytes(b"\x7fELF")
            files = RUNTIME.collect(self.pins, self.target, binaries, False, inspect=lambda path: clean)
        names = [row["name"] for row in files]
        self.assertEqual(names[:3], ["libggml-base.so.0", "libggml.so.0", "libwhisper.so.1"])
        self.assertNotIn("libparakeet.so.1", names, "Only the pinned modules are collected")
        whisper = files[2]
        self.assertEqual(whisper["bytes"], len(b"\x7fELF whisper"), "The soname link's target is recorded")
        self.assertEqual(sum(1 for row in files if row["kind"] == "cpu-backend"), 8)


if __name__ == "__main__":
    unittest.main()
