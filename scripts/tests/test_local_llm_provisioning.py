"""Source packager regressions; no native compilation, acquisition or model execution."""
import importlib.util
import pathlib
import re
import tempfile
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "local-llm-runtime" / "build-native-runtime.py"
SPEC = importlib.util.spec_from_file_location("jsti_llm_provisioning", SCRIPT)
PACKAGER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PACKAGER)


class LocalLLMProvisioningTests(unittest.TestCase):
    def test_exact_commit_and_clean_source_are_required(self):
        with mock.patch.object(PACKAGER, "command", side_effect=[PACKAGER.COMMIT, ""]) as command:
            source = pathlib.Path("source")
            self.assertEqual(PACKAGER.authenticate(source), source)
            self.assertEqual(command.call_count, 2)

    def test_wrong_pin_is_rejected_before_a_build(self):
        with mock.patch.object(PACKAGER, "command", return_value="0" * 40), \
                mock.patch.object(PACKAGER.subprocess, "run") as run:
            with self.assertRaisesRegex(ValueError, "pinned b6500"):
                PACKAGER.authenticate(pathlib.Path("source"))
            run.assert_not_called()

    def test_dirty_source_is_rejected(self):
        with mock.patch.object(PACKAGER, "command", side_effect=[PACKAGER.COMMIT, " M include/llama.h"]):
            with self.assertRaisesRegex(ValueError, "clean"):
                PACKAGER.authenticate(pathlib.Path("source"))

    def test_existing_output_is_never_overwritten(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            output = root / "LocalLLMRuntime"
            output.mkdir()
            marker = output / "retained"
            marker.write_text("existing data", encoding="utf-8")
            with mock.patch.object(PACKAGER, "authenticate", side_effect=lambda source: source), \
                    mock.patch.object(PACKAGER.platform, "system", return_value="Linux"), \
                    mock.patch.object(PACKAGER.platform, "machine", return_value="x86_64"), \
                    mock.patch.object(PACKAGER.subprocess, "run") as run:
                with self.assertRaisesRegex(ValueError, "never replaced"):
                    PACKAGER.build(root, output, root / "build")
                run.assert_not_called()
            self.assertEqual(marker.read_text(encoding="utf-8"), "existing data")

    def test_unsupported_host_is_rejected_without_subprocesses(self):
        with mock.patch.object(PACKAGER.platform, "system", return_value="Darwin"), \
                mock.patch.object(PACKAGER.platform, "machine", return_value="arm64"), \
                mock.patch.object(PACKAGER.subprocess, "run") as run:
            with self.assertRaisesRegex(ValueError, "natively on Windows/Linux"):
                PACKAGER.build(pathlib.Path("source"), pathlib.Path("output"), pathlib.Path("build"))
            run.assert_not_called()

    def test_packaged_exports_exactly_match_real_header_typed_adapter_symbols(self):
        adapter = (ROOT / "Sources" / "CLlamaCpp" / "LlamaCpp.cpp").read_text(encoding="utf-8")
        symbols = set(re.findall(r"X\((llama_[a-z0-9_]+)\)", adapter))
        exports = (ROOT / "scripts" / "local-llm-runtime" / "exports.def").read_text(encoding="utf-8")
        exported = set(re.findall(r"^\s+(llama_[a-z0-9_]+)\s*$", exports, re.MULTILINE))
        header = (ROOT / "Sources" / "CLlamaCpp" / "upstream" / "llama.h").read_text(encoding="utf-8")
        self.assertGreater(len(symbols), 20)
        self.assertEqual(symbols, exported)
        for symbol in symbols:
            self.assertRegex(header, r"\b" + symbol + r"\s*\(")

    def test_text_file_is_not_a_native_runtime(self):
        with tempfile.TemporaryDirectory() as temporary:
            binary = pathlib.Path(temporary) / "not-a-runtime"
            binary.write_text("not an executable image", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "ELF64"):
                PACKAGER.verify_binary(binary, "linux", "x86_64")

    def test_empty_file_cannot_generate_a_provisioning_manifest(self):
        with tempfile.TemporaryDirectory() as temporary:
            binary = pathlib.Path(temporary) / "empty"
            binary.write_bytes(b"")
            with self.assertRaisesRegex(ValueError, "size bound"):
                PACKAGER.verify_binary(binary, "linux", "x86_64")


if __name__ == "__main__":
    unittest.main()
