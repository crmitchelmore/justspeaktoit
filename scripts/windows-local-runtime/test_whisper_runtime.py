"""Checks that the whisper.cpp and llama.cpp pins, vendored headers and adapter agree."""
import contextlib
import hashlib
import importlib.util
import io
import json
import pathlib
import re
import subprocess
import sys
import tempfile
import types
import unittest
from unittest import mock

HERE = pathlib.Path(__file__).resolve().parent
REPOSITORY = HERE.parent.parent
VENDORED = REPOSITORY / "Sources" / "CWindowsSupport" / "whisper-cpp"
VENDORED_LLAMA = REPOSITORY / "Sources" / "CWindowsSupport" / "llama-cpp"
SHARED_GGML_HEADERS = ["ggml.h", "ggml-cpu.h", "ggml-backend.h", "ggml-alloc.h"]
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

    def test_vendored_llama_headers_match_their_provenance_and_the_runtime_pin(self):
        provenance = (VENDORED_LLAMA / "PROVENANCE.md").read_text(encoding="utf-8")
        llama = self.pins["llamaCpp"]
        self.assertIn(llama["commit"], provenance)
        self.assertIn("`" + llama["tag"] + "`", provenance)
        self.assertIn('`ggml_version()` is not `%s`' % llama["ggmlVersion"], provenance)
        rows = re.findall(r"\| `([^`]+)` \| `[^`]+` \| `([0-9a-f]{64})` \|", provenance)
        self.assertEqual({name for name, _ in rows}, {"llama.h", "ggml.h", "ggml-cpu.h", "ggml-backend.h",
                                                       "ggml-alloc.h", "ggml-opt.h", "gguf.h", "LICENSE"})
        self.assertEqual(sorted(path.name for path in VENDORED_LLAMA.iterdir()),
                         sorted([name for name, _ in rows] + ["PROVENANCE.md"]))
        for name, digest in rows:
            self.assertEqual(hashlib.sha256((VENDORED_LLAMA / name).read_bytes()).hexdigest(), digest, name)
        self.assertEqual(dict(rows)["LICENSE"], llama["licenseSHA256"])

    def test_both_runtimes_vendor_the_same_ggml_headers(self):
        # One ggml serves whisper.dll and llama.dll, so their declarations must be the same bytes.
        for name in SHARED_GGML_HEADERS:
            self.assertEqual((VENDORED / name).read_bytes(), (VENDORED_LLAMA / name).read_bytes(), name)

    def test_llama_is_pinned_beside_whisper_for_every_architecture(self):
        llama = self.pins["llamaCpp"]
        self.assertEqual(llama["repository"], "https://github.com/ggml-org/llama.cpp")
        self.assertRegex(llama["commit"], "^[0-9a-f]{40}$")
        self.assertRegex(llama["tag"], "^b[0-9]+$")
        self.assertRegex(llama["licenseSHA256"], "^[0-9a-f]{64}$")
        self.assertEqual((llama["license"], llama["module"], llama["ggmlVersion"]), ("MIT", "llama.dll", "0.23.0"))
        for architecture in ("x64", "arm64"):
            target = RUNTIME.architecture_pins(self.pins, architecture)
            self.assertEqual(target["requiredModules"][-1], "llama.dll")
            arguments, fallback, whisper = (target["llamaCmakeArguments"], target["llamaFallbackCmakeArguments"],
                                            target["cmakeArguments"])
            for required in ["-DLLAMA_USE_SYSTEM_GGML=ON", "-DBUILD_SHARED_LIBS=ON", "-DLLAMA_BUILD_IS_DEV=OFF",
                             "-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL", "-DLLAMA_BUILD_COMMON=OFF",
                             "-DLLAMA_BUILD_TESTS=OFF", "-DLLAMA_BUILD_TOOLS=OFF", "-DLLAMA_BUILD_EXAMPLES=OFF",
                             "-DLLAMA_BUILD_SERVER=OFF", "-DLLAMA_BUILD_APP=OFF", "-DLLAMA_OPENSSL=OFF"]:
                self.assertIn(required, arguments)
            # Same generator and compilers as that architecture's whisper.cpp build.
            self.assertEqual(arguments[:2], whisper[:2])
            self.assertEqual([value for value in arguments if "COMPILER" in value],
                             [value for value in whisper if "COMPILER" in value])
            self.assertFalse([value for value in arguments if value.startswith("-DGGML_")])
            # The fallback configures llama.cpp's identical ggml exactly as whisper.cpp configured its own.
            self.assertEqual([value for value in fallback if value.startswith("-DGGML_")],
                             [value for value in whisper if value.startswith("-DGGML_")])
            self.assertEqual([value for value in fallback if not value.startswith("-DGGML_")],
                             [value.replace("SYSTEM_GGML=ON", "SYSTEM_GGML=OFF") for value in arguments])

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
        self.assertEqual(arm64["requiredModules"],
                         ["whisper.dll", "ggml.dll", "ggml-base.dll", "ggml-cpu.dll", "llama.dll"])
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

    def test_collection_searches_several_build_directories_in_order(self):
        target = RUNTIME.architecture_pins(self.pins, "arm64")
        arm64 = BUNDLE_TESTS.PE.IMAGE_FILE_MACHINE_ARM64
        with tempfile.TemporaryDirectory() as directory:
            whisper, llama = pathlib.Path(directory) / "whisper", pathlib.Path(directory) / "llama"
            whisper.mkdir()
            llama.mkdir()
            for name in target["requiredModules"][:-1]:
                (whisper / name).write_bytes(BUNDLE_TESTS.build_pe(["KERNEL32.dll"], dll=True, machine=arm64))
            # A second ggml.dll in the later directory is never taken.
            (llama / "ggml.dll").write_bytes(BUNDLE_TESTS.build_pe(["USER32.dll"], dll=True, machine=arm64))
            with self.assertRaisesRegex(RUNTIME.RuntimeError_, "did not produce llama.dll"):
                RUNTIME.collect(target, self.policy, [whisper, llama], "arm64")
            (llama / "llama.dll").write_bytes(BUNDLE_TESTS.build_pe(["ggml.dll", "ggml-base.dll"], dll=True,
                                                                    machine=arm64))
            files = RUNTIME.collect(target, self.policy, [whisper, llama], "arm64")
            paths = {row["name"]: row["path"] for row in files}
            self.assertEqual(paths["ggml.dll"], whisper / "ggml.dll")
            self.assertEqual(paths["llama.dll"], llama / "llama.dll")
            RUNTIME.check_llama_imports(files)

    def test_llama_must_import_the_shared_ggml(self):
        def row(imports, delayed=()):
            return [{"name": "llama.dll", "imports": list(imports), "delayImports": list(delayed)}]
        RUNTIME.check_llama_imports(row(["ggml.dll", "ggml-base.dll", "KERNEL32.dll"]))
        RUNTIME.check_llama_imports(row(["ggml-base.dll"], ["ggml.dll"]))
        for imports, message in [(["KERNEL32.dll"], "no ggml module"), (["ggml.dll"], "imports ggml.dll;"),
                                 (["ggml-base.dll", "ggml-cpu.dll"], "ggml-cpu.dll")]:
            with self.assertRaisesRegex(RUNTIME.RuntimeError_, message):
                RUNTIME.check_llama_imports(row(imports))
        with self.assertRaisesRegex(RUNTIME.RuntimeError_, "did not produce llama.dll"):
            RUNTIME.check_llama_imports([])

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


class GGMLTreeTests(unittest.TestCase):
    """The shared-ggml check on synthetic trees."""

    def tree(self, root, files):
        for name, data in files.items():
            path = pathlib.Path(root) / "ggml" / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        return pathlib.Path(root)

    def test_identical_trees_share_one_digest_and_ignore_gitignore(self):
        files = {"CMakeLists.txt": b"project(ggml)\n", "include/ggml.h": b"#pragma once\n", "src/ggml.c": b"int x;\n"}
        with tempfile.TemporaryDirectory() as directory:
            whisper = self.tree(pathlib.Path(directory) / "whisper", dict(files, **{".gitignore": b"build\n"}))
            llama = self.tree(pathlib.Path(directory) / "llama", dict(files, **{".gitignore": b"other\n"}))
            digest = RUNTIME.shared_ggml_digest(whisper, llama)
            self.assertEqual(digest, RUNTIME.tree_digest(RUNTIME.ggml_tree(whisper / "ggml")))
            self.assertRegex(digest, "^[0-9a-f]{64}$")
            self.assertNotIn(".gitignore", RUNTIME.ggml_tree(llama / "ggml"))

    def test_any_changed_added_or_removed_file_is_refused(self):
        files = {"include/ggml.h": b"#pragma once\n", "src/ggml.c": b"int x;\n"}
        variants = [dict(files, **{"src/ggml.c": b"int y;\n"}), dict(files, **{"src/extra.c": b""}),
                    {"include/ggml.h": files["include/ggml.h"]}, dict(files, **{"src/.gitignore": b"x"})]
        for index, variant in enumerate(variants):
            with self.subTest(index=index), tempfile.TemporaryDirectory() as directory:
                whisper = self.tree(pathlib.Path(directory) / "whisper", files)
                llama = self.tree(pathlib.Path(directory) / "llama", variant)
                with self.assertRaisesRegex(RUNTIME.RuntimeError_, "ggml tree differs from whisper.cpp's in 1 files"):
                    RUNTIME.shared_ggml_digest(whisper, llama)

    def test_missing_or_empty_trees_are_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(RUNTIME.RuntimeError_, "no ggml tree"):
                RUNTIME.ggml_tree(pathlib.Path(directory) / "ggml")
            (pathlib.Path(directory) / "ggml").mkdir()
            with self.assertRaisesRegex(RUNTIME.RuntimeError_, "is empty"):
                RUNTIME.ggml_tree(pathlib.Path(directory) / "ggml")

    def test_the_research_copies_share_ggml_when_available(self):
        research = pathlib.Path("/Volumes/Memory/cache/jsti-llama-research")
        whisper, llama = research / "whisper.cpp-1.9.4", research / "llama.cpp-b10809"
        if not (whisper / "ggml").is_dir() or not (llama / "ggml").is_dir():
            self.skipTest("upstream source trees are not available on this host")
        RUNTIME.shared_ggml_digest(whisper, llama)


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


# --- main() end to end, with the external tools faked -------------------------------------
AMD64, ARM64 = BUNDLE_TESTS.PE.IMAGE_FILE_MACHINE_AMD64, BUNDLE_TESTS.PE.IMAGE_FILE_MACHINE_ARM64
X64_MODULES = ["whisper.dll", "ggml.dll", "ggml-base.dll", "ggml-vulkan.dll", "ggml-cpu-x64.dll",
               "ggml-cpu-sse42.dll", "ggml-cpu-haswell.dll", "ggml-cpu-icelake.dll"]
ARM64_MODULES = ["whisper.dll", "ggml.dll", "ggml-base.dll", "ggml-cpu.dll"]


class FakeBuildHost:
    """Stands in for git, vswhere/vcvarsall, CMake and the Vulkan SDK installer.

    Each fake leaves on disk what the real tool would (the checked-out licence
    and sample, the compiler description, the built DLLs, the SDK files), so
    main() runs its own checkout, authenticity, environment, collection and
    manifest code. Every command is recorded with the environment it received.
    """

    GGML = {"CMakeLists.txt": b"project(ggml)\n", "include/ggml.h": b"#pragma once\n", "src/ggml.c": b"int x;\n"}

    def __init__(self, root, architecture, head, licence, fixture, machine, vcvars_target=None, llama_head=None,
                 llama_licence=None, llama_ggml=None, llama_imports=None, system_ggml_fails=False):
        self.root, self.architecture, self.head = root, architecture, head
        self.licence, self.fixture = licence, fixture
        self.llama_head = llama_head or RUNTIME.load_pins()["llamaCpp"]["commit"]
        self.llama_licence = licence if llama_licence is None else llama_licence
        self.llama_ggml = self.GGML if llama_ggml is None else llama_ggml
        self.llama_imports = llama_imports or ["ggml.dll", "ggml-base.dll", "KERNEL32.dll", "MSVCP140.dll"]
        self.system_ggml_fails = system_ggml_fails
        self.machine = machine
        self.modules = {name: machine for name in (ARM64_MODULES if architecture == "arm64" else X64_MODULES)}
        self.vcvars_target = vcvars_target or architecture
        self.commands, self.downloads = [], []
        self.installation = root / "Microsoft Visual Studio" / "2022" / "Enterprise"
        (self.installation / "VC" / "Auxiliary" / "Build").mkdir(parents=True)
        (self.installation / "VC" / "Auxiliary" / "Build" / "vcvarsall.bat").write_text("@rem\n", encoding="utf-8")
        environ = {"PATH": "C:\\Windows\\System32", "ProgramFiles(x86)": str(root / "Program Files (x86)")}
        self.os = types.SimpleNamespace(name="nt", environ=environ, pathsep=";", cpu_count=lambda: 4)
        self.subprocess = types.SimpleNamespace(run=self.subprocess_run, CalledProcessError=subprocess.CalledProcessError)

    def command(self, prefix):
        return [argv for argv, _ in self.commands if isinstance(argv, list) and argv[:len(prefix)] == prefix]

    def run(self, command, **kwargs):
        argv = [str(part) for part in command]
        self.commands.append((argv, kwargs.get("env")))
        if argv[0] == "git" and argv[3:4] == ["checkout"]:
            source = pathlib.Path(argv[2])
            llama = source.name == "llama.cpp"
            (source / "LICENSE").write_bytes(self.llama_licence if llama else self.licence)
            ggml = self.llama_ggml if llama else self.GGML
            for name, data in dict(ggml, **{".gitignore": b"llama\n" if llama else b"whisper\n"}).items():
                (source / "ggml" / name).parent.mkdir(parents=True, exist_ok=True)
                (source / "ggml" / name).write_bytes(data)
            if not llama:
                (source / "samples").mkdir(parents=True, exist_ok=True)
                (source / "samples" / "jfk.wav").write_bytes(self.fixture)
        elif argv[:2] == ["cmake", "--install"]:
            (pathlib.Path(argv[6]) / "lib" / "cmake" / "ggml").mkdir(parents=True)
        elif argv[:2] == ["cmake", "-S"] and pathlib.Path(argv[2]).name == "llama.cpp":
            if self.system_ggml_fails and "-DLLAMA_USE_SYSTEM_GGML=ON" in argv:
                pathlib.Path(argv[4]).mkdir(parents=True, exist_ok=True)
                raise subprocess.CalledProcessError(1, argv)
        elif argv[:2] == ["cmake", "--build"] and "llama" in argv:
            binaries = pathlib.Path(argv[2]) / "bin" / "Release"
            binaries.mkdir(parents=True)
            (binaries / "llama.dll").write_bytes(BUNDLE_TESTS.build_pe(self.llama_imports, dll=True,
                                                                       machine=self.machine))
            # llama.cpp's own ggml (fallback) must never replace the whisper.cpp build's.
            (binaries / "ggml.dll").write_bytes(BUNDLE_TESTS.build_pe(["USER32.dll"], dll=True, machine=self.machine))
        elif argv[:2] == ["cmake", "-S"]:
            compiler = (("Clang", "22.1.8", "C:/Program Files/LLVM/bin/clang++.exe") if self.architecture == "arm64"
                        else ("MSVC", "19.44.35222.0", "C:/VS/VC/Tools/MSVC/14.44.35207/bin/Hostx64/x64/cl.exe"))
            description = pathlib.Path(argv[4]) / "CMakeFiles" / "4.4.3" / "CMakeCXXCompiler.cmake"
            description.parent.mkdir(parents=True)
            description.write_text('set(CMAKE_CXX_COMPILER "%s")\nset(CMAKE_CXX_COMPILER_ID "%s")\n'
                                   'set(CMAKE_CXX_COMPILER_VERSION "%s")\n' % (compiler[2], compiler[0], compiler[1]),
                                   encoding="utf-8")
        elif argv[:2] == ["cmake", "--build"]:
            binaries = pathlib.Path(argv[2]) / "bin" / "Release"
            binaries.mkdir(parents=True)
            for name, machine in self.modules.items():
                imports = ["ggml-base.dll", "KERNEL32.dll", "MSVCP140.dll", "VCRUNTIME140.dll"]
                imports += ["vulkan-1.dll"] if name == "ggml-vulkan.dll" else []
                (binaries / name).write_bytes(BUNDLE_TESTS.build_pe(imports, dll=True, machine=machine))
            # Built but not part of the runtime; collection must leave it out.
            (binaries / "whisper-helper.dll").write_bytes(BUNDLE_TESTS.build_pe(["KERNEL32.dll"], dll=True))
        elif argv[1:2] == ["--root"]:
            sdk = pathlib.Path(argv[2])
            (sdk / "Include" / "vulkan").mkdir(parents=True)
            (sdk / "Include" / "vulkan" / "vulkan.h").write_text("/* SDK fixture */\n", encoding="utf-8")
            (sdk / "Bin").mkdir()
            (sdk / "Bin" / "glslc.exe").write_bytes(b"MZ")

    def subprocess_run(self, command, **kwargs):
        if isinstance(command, str):
            self.commands.append((command, kwargs.get("env")))
            output = ["Path=C:\\VS\\VC\\Tools\\MSVC\\bin\\HostARM64\\ARM64;C:\\Windows\\System32",
                      "LIB=C:\\VS\\VC\\Tools\\MSVC\\lib\\ARM64", "VSCMD_ARG_TGT_ARCH=" + self.vcvars_target, "=C:=C:\\a"]
            return subprocess.CompletedProcess(command, 0, stdout="\n".join(output) + "\n", stderr="")
        argv = [str(part) for part in command]
        self.commands.append((argv, kwargs.get("env")))
        if argv[0].endswith("vswhere.exe"):
            return subprocess.CompletedProcess(argv, 0, stdout=str(self.installation) + "\n", stderr="")
        if argv[0] == "git" and argv[-2:] == ["rev-parse", "HEAD"]:
            head = self.llama_head if pathlib.Path(argv[2]).name == "llama.cpp" else self.head
            return subprocess.CompletedProcess(argv, 0, stdout=head + "\n", stderr="")
        raise AssertionError("unexpected external command %r" % (argv,))

    def download(self, entry, directory):
        self.downloads.append(entry)
        directory.mkdir(parents=True, exist_ok=True)
        (directory / entry["name"]).write_bytes(b"MZ installer fixture")
        return directory / entry["name"]


class MainExecutionTests(unittest.TestCase):
    """main() runs checkout, authenticity checks, configure, build, collection and the manifest.

    Only the external tools are faked. The whisper.cpp commit, repository,
    licence digest, CMake arguments and Vulkan SDK are the real pins; the
    licence is the repository's vendored copy of the pinned text. Only the
    JFK sample's digest is replaced, because the sample is not in this
    repository. The runtime main() writes must then be accepted by the bundle
    builder against the real pin file.
    """

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        # main() resolves --work and --output, so compare against resolved paths.
        self.root = pathlib.Path(self.directory.name).resolve()
        self.real = RUNTIME.load_pins()
        self.licence = (VENDORED / "LICENSE").read_bytes()
        self.fixture = b"RIFF synthetic JFK sample"
        self.pins = json.loads(json.dumps(self.real))
        self.pins["whisperCpp"]["fixture"].update(sha256=hashlib.sha256(self.fixture).hexdigest(), bytes=len(self.fixture))

    def host(self, architecture, root=None, **options):
        values = dict(head=self.real["whisperCpp"]["commit"], licence=self.licence, fixture=self.fixture,
                      machine=ARM64 if architecture == "arm64" else AMD64)
        values.update(options)
        return FakeBuildHost(root or self.root, architecture, **values)

    def execute(self, host):
        output, work = host.root / "output", host.root / "work"
        with mock.patch.multiple(RUNTIME, os=host.os, subprocess=host.subprocess, run=host.run, download=host.download,
                                 load_pins=lambda: json.loads(json.dumps(self.pins))), \
                contextlib.redirect_stdout(io.StringIO()):
            RUNTIME.main(["--architecture", host.architecture, "--output", str(output), "--work", str(work),
                          "--jobs", "3"])
        return output, work

    def check_output(self, output, architecture, modules):
        manifest = json.loads((output / "runtime-manifest.json").read_text(encoding="utf-8"))
        target = self.real["architectures"][architecture]
        whisper = self.real["whisperCpp"]
        self.assertEqual((manifest["architecture"], manifest["commit"], manifest["repository"], manifest["version"]),
                         (architecture, whisper["commit"], whisper["repository"], whisper["version"]))
        self.assertEqual(manifest["cmakeArguments"], target["cmakeArguments"])
        self.assertEqual(manifest["pinsSHA256"], RUNTIME.pins_digest(RUNTIME.HERE / "dependencies.json"))
        modules = modules + ["llama.dll"]
        self.assertEqual([row["name"] for row in manifest["files"]], sorted(modules))
        self.assertEqual({row["architecture"] for row in manifest["files"]}, {architecture})
        self.assertEqual(sorted(path.name for path in (output / "runtime").iterdir()),
                         sorted(modules + ["LICENSE-whisper.cpp.txt", "LICENSE-llama.cpp.txt"]))
        # The shipped ggml.dll is the whisper.cpp build's, not the one beside llama.dll.
        ggml = next(row for row in manifest["files"] if row["name"] == "ggml.dll")
        self.assertEqual(ggml["imports"], ["ggml-base.dll", "KERNEL32.dll", "MSVCP140.dll", "VCRUNTIME140.dll"])
        llama, pins = manifest["llamaCpp"], self.real["llamaCpp"]
        self.assertEqual((llama["commit"], llama["tag"], llama["repository"], llama["ggmlVersion"]),
                         (pins["commit"], pins["tag"], pins["repository"], pins["ggmlVersion"]))
        self.assertEqual(llama["ggmlTreeSHA256"], RUNTIME.tree_digest(
            {name: hashlib.sha256(data).hexdigest() for name, data in FakeBuildHost.GGML.items()}))
        self.assertEqual(manifest["schemaVersion"], 3)
        self.assertEqual((output / "fixtures" / "jfk.wav").read_bytes(), self.fixture)
        # The bundle builder authenticates exactly this output against the real pins.
        runtime = BUNDLE_TESTS.BUILD.load_local_runtime(output, RUNTIME.HERE / "dependencies.json", architecture)
        self.assertEqual(sorted(runtime["modules"]), sorted(name.lower() for name in modules))
        self.assertEqual(runtime["modules"]["llama.dll"]["provenance"]["runtime"], "llama.cpp")
        return manifest

    def check_source_commands(self, host, work):
        source, whisper = str(work / "whisper.cpp"), self.real["whisperCpp"]
        self.assertEqual(host.command(["git", "-C", source, "remote", "add"]),
                         [["git", "-C", source, "remote", "add", "origin", whisper["repository"]]])
        self.assertEqual(host.command(["git", "-C", source, "fetch"]),
                         [["git", "-C", source, "fetch", "-q", "--depth", "1", "origin", whisper["commit"]]])
        # git subcommands follow "-C <source>" except for init; cmake's mode is its first argument.
        llama, pins = str(work / "llama.cpp"), self.real["llamaCpp"]
        self.assertEqual(host.command(["git", "-C", llama, "fetch"]),
                         [["git", "-C", llama, "fetch", "-q", "--depth", "1", "origin", pins["commit"]]])
        self.assertEqual(host.command(["git", "-C", llama, "config"]),
                         [["git", "-C", llama, "config", "core.autocrlf", "false"]])
        order = [argv[3] if argv[:2] == ["git", "-C"] else argv[1] for argv, _ in host.commands
                 if isinstance(argv, list) and argv[0] in ("git", "cmake")]
        checkout = ["init", "remote", "config", "fetch", "checkout", "rev-parse"]
        self.assertEqual(order, checkout + ["-S", "--build"] + checkout + ["--install", "-S", "--build"])
        (install, _), = [(argv, env) for argv, env in host.commands
                         if isinstance(argv, list) and argv[:2] == ["cmake", "--install"]]
        self.assertEqual(install, ["cmake", "--install", str(work / "build"), "--config", "Release", "--prefix",
                                   str(work / "ggml-stage")])

    def configured(self, host, work):
        configures = [(argv, env) for argv, env in host.commands
                      if isinstance(argv, list) and argv[:2] == ["cmake", "-S"]]
        (configure, environment), (llama_configure, llama_environment) = configures
        self.assertEqual(configure[:5], ["cmake", "-S", str(work / "whisper.cpp"), "-B", str(work / "build")])
        builds = [(argv, env) for argv, env in host.commands if isinstance(argv, list) and argv[:2] == ["cmake", "--build"]]
        (build, build_environment), (llama_build, llama_build_environment) = builds
        self.assertEqual(build, ["cmake", "--build", str(work / "build"), "--config", "Release", "--parallel", "3"])
        self.assertIs(build_environment, environment)
        target = self.real["architectures"][host.architecture]
        self.assertEqual(llama_configure, ["cmake", "-S", str(work / "llama.cpp"), "-B", str(work / "llama-build")]
                         + target["llamaCmakeArguments"] + ["-DCMAKE_PREFIX_PATH=" + (work / "ggml-stage").as_posix()])
        self.assertEqual(llama_build, ["cmake", "--build", str(work / "llama-build"), "--config", "Release",
                                       "--target", "llama", "--parallel", "3"])
        self.assertIs(llama_environment, environment)
        self.assertIs(llama_build_environment, environment)
        return configure[5:], environment

    def test_x64_builds_with_the_pinned_vulkan_sdk_and_msvc(self):
        host = self.host("x64")
        output, work = self.execute(host)
        target = self.real["architectures"]["x64"]
        arguments, environment = self.configured(host, work)
        self.assertEqual(arguments, target["cmakeArguments"])
        self.assertEqual(host.downloads, [target["vulkanSdk"]])
        sdk = work / "VulkanSDK" / target["vulkanSdk"]["version"]
        self.assertEqual(environment["VULKAN_SDK"], str(sdk))
        self.assertTrue(environment["PATH"].startswith(str(sdk / "Bin") + ";"))
        self.assertFalse([argv for argv, _ in host.commands if isinstance(argv, str) or "vswhere" in argv[0]])
        self.check_source_commands(host, work)
        manifest = self.check_output(output, "x64", X64_MODULES)
        self.assertEqual(manifest["vulkanSdk"], {key: target["vulkanSdk"][key] for key in ("version", "sha256", "bytes")})
        self.assertEqual(manifest["compiler"], "MSVC 19.44.35222.0")

    def test_arm64_builds_on_the_cpu_inside_the_arm64_developer_environment(self):
        host = self.host("arm64")
        output, work = self.execute(host)
        arguments, environment = self.configured(host, work)
        self.assertEqual(arguments, self.real["architectures"]["arm64"]["cmakeArguments"])
        vswhere = [argv for argv, _ in host.commands if isinstance(argv, list) and argv[0].endswith("vswhere.exe")]
        self.assertEqual(vswhere[0][vswhere[0].index("-requires") + 1], "Microsoft.VisualStudio.Component.VC.Tools.ARM64")
        vcvarsall = [argv for argv, _ in host.commands if isinstance(argv, str)]
        self.assertEqual(len(vcvarsall), 1)
        self.assertIn('vcvarsall.bat" arm64 ', vcvarsall[0])
        self.assertEqual(environment["VSCMD_ARG_TGT_ARCH"], "arm64")
        self.assertNotIn("VULKAN_SDK", environment)
        self.assertNotIn("=C:", environment)
        self.assertEqual(host.downloads, [])
        self.check_source_commands(host, work)
        manifest = self.check_output(output, "arm64", ARM64_MODULES)
        self.assertIsNone(manifest["vulkanSdk"])
        self.assertEqual((manifest["compiler"], manifest["compilerPath"]),
                         ("Clang 22.1.8", "C:/Program Files/LLVM/bin/clang++.exe"))

    def test_unpinned_source_foreign_images_or_wrong_environment_publish_nothing(self):
        # (architecture, fault, expected refusal, whether CMake ran before it)
        cases = [
            ("x64", {"head": "0" * 40}, "checkout is 0{40}, not the pinned", False),
            ("arm64", {"licence": self.licence + b"\nchanged"}, "licence differs from the pinned text", False),
            ("arm64", {"fixture": b"another sample"}, "JFK fixture differs from its pin", False),
            ("arm64", {"vcvars_target": "x64"}, "did not enter the arm64 developer environment", False),
            ("arm64", {"machine": AMD64}, "is not a native arm64 DLL \\(it is x64\\)", True),
            ("x64", {"llama_head": "1" * 40}, "llama.cpp checkout is 1{40}, not the pinned", True),
            ("arm64", {"llama_licence": b"another licence"}, "llama.cpp licence differs", True),
            ("arm64", {"llama_ggml": dict(FakeBuildHost.GGML, **{"src/ggml.c": b"int y;\n"})},
             "ggml tree differs from whisper.cpp's in 1 files \\(first: src/ggml.c\\)", True),
            ("x64", {"llama_imports": ["ggml-base.dll", "ggml-vulkan.dll", "KERNEL32.dll"]},
             "llama.dll imports ggml-base.dll, ggml-vulkan.dll", True),
        ]
        for index, (architecture, options, message, built) in enumerate(cases):
            with self.subTest(architecture=architecture, fault=sorted(options)):
                host = self.host(architecture, self.root / ("case-%d" % index), **options)
                with self.assertRaisesRegex(RUNTIME.RuntimeError_, message):
                    self.execute(host)
                self.assertEqual(bool(host.command(["cmake"])), built)
                self.assertFalse((host.root / "output" / "runtime-manifest.json").exists())

    def test_llama_falls_back_to_its_identical_ggml_tree_when_cmake_cannot_find_the_installed_one(self):
        host = self.host("x64", system_ggml_fails=True)
        output, work = self.execute(host)
        target = self.real["architectures"]["x64"]
        configures = [argv for argv, _ in host.commands if isinstance(argv, list) and argv[:2] == ["cmake", "-S"]
                      and argv[2] == str(work / "llama.cpp")]
        self.assertEqual(configures[1], ["cmake", "-S", str(work / "llama.cpp"), "-B", str(work / "llama-build")]
                         + target["llamaFallbackCmakeArguments"])
        manifest = self.check_output(output, "x64", X64_MODULES)
        self.assertEqual(manifest["llamaCpp"]["cmakeArguments"], target["llamaFallbackCmakeArguments"])
        self.assertEqual(manifest["llamaCpp"]["ggmlSource"], "llama.cpp tree identical to whisper.cpp's")

    def test_non_windows_hosts_are_refused_before_any_command(self):
        host = self.host("x64")
        host.os.name = "posix"
        with self.assertRaisesRegex(SystemExit, "runs on Windows only"):
            self.execute(host)
        self.assertEqual(host.commands, [])


if __name__ == "__main__":
    unittest.main()
