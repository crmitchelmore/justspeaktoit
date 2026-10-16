"""Source regressions using synthetic image metadata, never executable/native inference."""
import importlib.util
import json
import pathlib
import struct
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


BUNDLE_TESTS = load("llm_bundle_fixtures", "scripts/windows-bundle/test_windows_bundle.py")
PACKAGE_TESTS = load("llm_msix_fixtures", "scripts/windows-package/test_windows_package.py")
BUILD = BUNDLE_TESTS.BUILD
PACKAGE = BUILD.local_llm_package
MSIX = PACKAGE_TESTS.windows_msix
LINUX = load("llm_linux_staging", "scripts/stage-linux-desktop.py")
LICENSE = (ROOT / "Sources/CLlamaCpp/upstream/LICENSE").read_bytes()


def elf_metadata(architecture="x86_64", needed=("libc.so.6", "libstdc++.so.6"), search="$ORIGIN"):
    data = bytearray(2048)
    data[:7] = b"\x7fELF\x02\x01\x01"
    struct.pack_into("<HHI", data, 16, 3, 62 if architecture == "x86_64" else 183, 1)
    struct.pack_into("<Q", data, 32, 64)
    struct.pack_into("<HHH", data, 52, 64, 56, 2)
    strings = bytearray(b"\0")

    def text(value):
        offset = len(strings)
        strings.extend(value.encode("ascii") + b"\0")
        return offset

    tags = [(1, text(value)) for value in needed]
    if search is not None:
        tags.append((29, text(search)))
    tags += [(14, text("libllama.so")), (5, 0x1200), (10, len(strings)), (0, 0)]
    data[512:512 + len(strings)] = strings
    dynamic = b"".join(struct.pack("<qQ", tag, value) for tag, value in tags)
    data[1024:1024 + len(dynamic)] = dynamic
    struct.pack_into("<IIQQQQQQ", data, 64, 1, 5, 0, 0x1000, 0, len(data), len(data), 4096)
    struct.pack_into("<IIQQQQQQ", data, 120, 2, 4, 1024, 0x1400, 0, len(dynamic), len(dynamic), 8)
    return bytes(data)


def payload(system="windows", architecture="x86_64", binary=None):
    if binary is None:
        binary = (BUNDLE_TESTS.build_pe(
            imports=["KERNEL32.dll"], dll=True,
            machine=BUNDLE_TESTS.PE.IMAGE_FILE_MACHINE_AMD64 if architecture == "x86_64"
            else BUNDLE_TESTS.PE.IMAGE_FILE_MACHINE_ARM64)
            if system == "windows" else elf_metadata(architecture))
    library = "llama.dll" if system == "windows" else "libllama.so"
    manifest = {"schemaVersion": 1, "commit": PACKAGE.COMMIT, "platform": system, "architecture": architecture,
                "library": library, "sha256": PACKAGE.digest(binary)}
    return {library: binary, "provisioning.json": json.dumps(manifest).encode(), "LICENSE.llama-cpp": LICENSE}


def write_payload(directory, entries):
    directory.mkdir()
    for name, data in entries.items():
        (directory / name).write_bytes(data)


class LocalLLMDistributionTests(unittest.TestCase):
    def test_native_windows_and_linux_architectures_are_checked_without_loading(self):
        for system in ("windows", "linux"):
            for architecture in ("x86_64", "arm64"):
                with self.subTest(system=system, architecture=architecture):
                    entries = payload(system, architecture)
                    result = PACKAGE.validate_entries(entries, system, architecture)
                    self.assertEqual(result["entries"], entries)
                    self.assertEqual(result["manifest"]["commit"], PACKAGE.COMMIT)

    def test_runtime_pin_hash_platform_and_schema_cannot_be_substituted(self):
        for key, value in (("commit", "0" * 40), ("sha256", "0" * 64), ("platform", "linux"),
                           ("architecture", "arm64"), ("schemaVersion", True), ("library", "../llama.dll")):
            with self.subTest(key=key):
                entries = payload()
                manifest = json.loads(entries["provisioning.json"])
                manifest[key] = value
                entries["provisioning.json"] = json.dumps(manifest).encode()
                with self.assertRaisesRegex(ValueError, "pin/target/library/hash"):
                    PACKAGE.validate_entries(entries, "windows", "x86_64")

    def test_duplicate_manifest_keys_are_rejected(self):
        entries = payload()
        entries["provisioning.json"] = entries["provisioning.json"].replace(
            b'"schemaVersion": 1', b'"schemaVersion": 1, "schemaVersion": 1')
        with self.assertRaisesRegex(ValueError, "repeats a key"):
            PACKAGE.validate_entries(entries, "windows", "x86_64")

    def test_license_bytes_are_authenticated_not_merely_named(self):
        entries = payload()
        entries["LICENSE.llama-cpp"] = b"MIT License, but not the pinned upstream notice"
        with self.assertRaisesRegex(ValueError, "pinned MIT"):
            PACKAGE.validate_entries(entries, "windows", "x86_64")

    def test_missing_and_additional_payload_entries_are_rejected(self):
        for missing in (False, True):
            entries = payload()
            if missing:
                entries.pop("LICENSE.llama-cpp")
            else:
                entries["backend.dll"] = b"not an approved payload"
            with self.assertRaisesRegex(ValueError, "exactly"):
                PACKAGE.validate_entries(entries, "windows", "x86_64")

    def test_manifest_size_is_bounded_before_decode(self):
        entries = payload()
        entries["provisioning.json"] = b" " * 16_385
        with self.assertRaisesRegex(ValueError, "size bound"):
            PACKAGE.validate_entries(entries, "windows", "x86_64")

    def test_windows_dynamic_crt_and_delayed_backend_dependencies_are_rejected(self):
        for arguments in ({"imports": ["VCRUNTIME140.dll"]}, {"delay_imports": ["ggml.dll"]},
                          {"imports": ["vulkan-1.dll"]}):
            with self.subTest(arguments=arguments):
                entries = payload(binary=BUNDLE_TESTS.build_pe(dll=True, **arguments))
                with self.assertRaisesRegex(ValueError, "static MSVC"):
                    PACKAGE.validate_entries(entries, "windows", "x86_64")

    def test_wrong_machine_cannot_be_admitted_by_rehashing_the_manifest(self):
        entries = payload(architecture="arm64")
        manifest = json.loads(entries["provisioning.json"])
        manifest["architecture"] = "x86_64"
        entries["provisioning.json"] = json.dumps(manifest).encode()
        with self.assertRaisesRegex(ValueError, "exact Windows architecture"):
            PACKAGE.validate_entries(entries, "windows", "x86_64")

    def test_linux_non_system_backend_dependency_is_rejected(self):
        entries = payload("linux", binary=elf_metadata(needed=("libggml-cpu.so",)))
        with self.assertRaisesRegex(ValueError, "unapproved/non-system"):
            PACKAGE.validate_entries(entries, "linux", "x86_64")

    def test_linux_hidden_filter_and_audit_dependencies_are_rejected(self):
        for tag in (0x7FFFFFFF, 0x7FFFFFFD, 0x6FFFFEFC, 0x6FFFFEFB):
            binary = bytearray(elf_metadata())
            struct.pack_into("<q", binary, 1024, tag)
            with self.subTest(tag=tag), self.assertRaisesRegex(ValueError, "filters and audit"):
                PACKAGE.validate_entries(payload("linux", binary=bytes(binary)), "linux", "x86_64")

    def test_linux_external_and_multi_directory_search_paths_are_rejected(self):
        for search in ("/tmp/untrusted", "$ORIGIN:/usr/local/lib", ""):
            entries = payload("linux", binary=elf_metadata(search=search))
            with self.assertRaisesRegex(ValueError, "exactly .ORIGIN"):
                PACKAGE.validate_entries(entries, "linux", "x86_64")

    def test_linux_program_headers_and_dynamic_strings_are_bounded(self):
        for offset, format_string, value in ((32, "<Q", 2040), (54, "<H", 1), (56, "<H", 0),
                                              (64 + 32, "<Q", 99999), (1024 + 8, "<Q", 99999)):
            binary = bytearray(elf_metadata())
            struct.pack_into(format_string, binary, offset, value)
            with self.subTest(offset=offset), self.assertRaises(ValueError):
                PACKAGE.validate_entries(payload("linux", binary=bytes(binary)), "linux", "x86_64")

    def test_directory_reader_rejects_subdirectories_and_unexpected_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary) / "runtime"
            write_payload(root, payload())
            (root / "extra").mkdir()
            with self.assertRaisesRegex(ValueError, "unexpected"):
                PACKAGE.read_directory(root, "windows", "x86_64")
            (root / "extra").rmdir()
            (root / "llama.dll").unlink()
            (root / "llama.dll").mkdir()
            with self.assertRaisesRegex(ValueError, "regular"):
                PACKAGE.read_directory(root, "windows", "x86_64")

    def test_directory_reader_returns_exact_authenticated_bytes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary) / "runtime"
            entries = payload()
            write_payload(root, entries)
            self.assertEqual(PACKAGE.read_directory(root, "windows", "x86_64")["entries"], entries)

    def make_assembly(self, architecture="x64"):
        fixture = BUNDLE_TESTS.AssemblyTests()
        fixture.setUp(architecture)
        self.addCleanup(fixture.doCleanups)
        fixture.application["metadata"]["sourceCommit"] = PACKAGE_TESTS.COMMIT
        native = PACKAGE.validate_entries(payload(architecture="x86_64" if architecture == "x64" else "arm64"),
                                          "windows", "x86_64" if architecture == "x64" else "arm64")
        return fixture, native

    def test_windows_bundle_retains_nested_payload_and_runtime_dependency_root(self):
        for architecture in ("x64", "arm64"):
            fixture, native = self.make_assembly(architecture)
            entries, manifest = fixture.assemble(
                architecture=architecture, local_llm=native, policy=BUILD.Policy.load(local_runtime=["llama.dll"]))
            self.assertNotIn("llama.dll", entries)
            self.assertEqual(entries["LocalLLMRuntime/llama.dll"], native["entries"]["llama.dll"])
            self.assertEqual(manifest["sources"]["localLLMRuntime"], BUILD.local_llm_source(native))
            self.assertIsNone(manifest["sources"]["localInferenceRuntime"])
            self.assertEqual(manifest["dependencies"]["bundled"]["llama.dll"]["source"], BUILD.LOCAL_RUNTIME)
            for name, data in native["entries"].items():
                row = next(row for row in manifest["files"] if row["path"] == "LocalLLMRuntime/" + name)
                self.assertEqual(row["sha256"], PACKAGE.digest(data))

    def test_transcription_and_cleanup_runtime_source_records_remain_distinct(self):
        fixture, native = self.make_assembly()
        whisper = {"modules": {"whisper.dll": {"name": "whisper.dll", "bytes": BUNDLE_TESTS.build_pe(
            imports=["KERNEL32.dll"], dll=True), "provenance": {"fixture": True}}},
            "license": b"MIT fixture", "manifestSHA256": "fixture",
            "manifest": {"runtime": "whisper.cpp", "version": "fixture", "commit": "fixture",
                         "repository": "https://github.com/ggml-org/whisper.cpp", "vulkanSdk": None,
                         "compiler": "fixture"}}
        entries, manifest = fixture.assemble(
            local_runtime=whisper, local_llm=native,
            policy=BUILD.Policy.load(local_runtime=["whisper.dll", "llama.dll"]))
        self.assertEqual(manifest["sources"]["localInferenceRuntime"]["modules"], ["whisper.dll"])
        self.assertEqual(manifest["sources"]["localLLMRuntime"]["libraryPath"], "LocalLLMRuntime/llama.dll")
        self.assertIn("whisper.dll", entries)
        self.assertNotIn("llama.dll", entries)

    def test_bundle_requires_explicit_runtime_policy_admission(self):
        fixture, native = self.make_assembly()
        with self.assertRaisesRegex(BUILD.BundleError, "policy was not loaded"):
            fixture.assemble(local_llm=native)

    def test_msix_consumer_reauthenticates_payload_despite_matching_outer_hashes(self):
        fixture, native = self.make_assembly()
        for mutation in ("pin", "license", "flatten", "record"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                entries, manifest = fixture.assemble(
                    local_llm=native, policy=BUILD.Policy.load(local_runtime=["llama.dll"]))
                if mutation == "pin":
                    path = "LocalLLMRuntime/provisioning.json"
                    parsed = json.loads(entries[path])
                    parsed["commit"] = "0" * 40
                    entries[path] = json.dumps(parsed).encode()
                elif mutation == "license":
                    entries["LocalLLMRuntime/LICENSE.llama-cpp"] = b"modified MIT notice"
                elif mutation == "flatten":
                    entries["llama.dll"] = entries.pop("LocalLLMRuntime/llama.dll")
                    next(row for row in manifest["files"] if row["path"] == "LocalLLMRuntime/llama.dll")[
                        "path"] = "llama.dll"
                else:
                    manifest["sources"]["localLLMRuntime"]["manifestSHA256"] = "0" * 64
                for row in manifest["files"]:
                    row["bytes"], row["sha256"] = len(entries[row["path"]]), PACKAGE.digest(entries[row["path"]])
                directory = PACKAGE_TESTS.write_bundle(pathlib.Path(temporary), entries, manifest, "x64")
                with self.assertRaises(MSIX.PackageError):
                    MSIX.verify_bundle(directory)

    def test_msix_layout_preserves_nested_payload_bytes(self):
        fixture, native = self.make_assembly()
        entries, manifest = fixture.assemble(
            local_llm=native, policy=BUILD.Policy.load(local_runtime=["llama.dll"]))
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            directory = PACKAGE_TESTS.write_bundle(root / "bundle", entries, manifest, "x64")
            MSIX.build_layout(directory, root / "package", "1.0.0.0")
            MSIX.verify_layout(root / "package/layout")
            for name, data in native["entries"].items():
                self.assertEqual((root / "package/layout/LocalLLMRuntime" / name).read_bytes(), data)

    def make_linux_app(self, root):
        binary = root / "SpeakLinux"
        binary.write_bytes(elf_metadata())
        (root / "SpeakApp_SpeakCore.resources").mkdir()
        theme = root / "SpeakApp_SpeakLinux.resources/hicolor"
        theme.mkdir(parents=True)
        (theme / "index.theme").write_text("private theme", encoding="utf-8")
        return binary

    def test_linux_staging_retains_runtime_manifest_license_and_library(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            binary = self.make_linux_app(root)
            entries = payload("linux")
            write_payload(root / "runtime", entries)
            LINUX.stage(binary, root / "output", local_llm_runtime=root / "runtime")
            for name, data in entries.items():
                self.assertEqual((root / "output/bin/LocalLLMRuntime" / name).read_bytes(), data)

    def test_linux_staging_rejects_foreign_architecture_before_output_creation(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            binary = self.make_linux_app(root)
            write_payload(root / "runtime", payload("linux", architecture="arm64"))
            with self.assertRaisesRegex(ValueError, "pin/target/library/hash"):
                LINUX.stage(binary, root / "output", local_llm_runtime=root / "runtime")
            self.assertFalse((root / "output").exists())

    def test_linux_staging_without_runtime_keeps_existing_optional_behavior(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            binary = self.make_linux_app(root)
            LINUX.stage(binary, root / "output")
            self.assertFalse((root / "output/bin/LocalLLMRuntime").exists())
            self.assertTrue((root / "output/share/applications" / (LINUX.APP_ID + ".desktop")).is_file())


if __name__ == "__main__":
    unittest.main()
