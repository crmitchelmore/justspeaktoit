"""Exercise the real symbol-preparation shell with owned, inert tool fixtures."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
PREPARE = ROOT / "scripts/prepare-mac-cli-symbols.sh"
FAKE_TOOL = r'''
import json, os, pathlib, sys
tool, args = sys.argv[1], sys.argv[2:]
with open(os.environ['FAKE_LOG'], 'a') as stream:
    stream.write(json.dumps([tool, *args]) + '\n')
mode = os.environ.get('FAKE_MODE', '')
uuid = os.environ.get('FAKE_UUID', '2540060A-29D8-3E14-B054-000E88C279AC')
other = '3540060A-29D8-3E14-B054-000E88C279AC'
if tool == 'strip-fake':
    assert args[0] == '-S' and len(args) == 2
    if mode == 'strip-failure': sys.exit(1)
    p = pathlib.Path(args[1]); p.write_bytes(p.read_bytes() + b'|stripped')
elif tool == 'codesign':
    print('runtime', file=sys.stderr)
elif tool == 'lipo':
    if args[0] == '-create':
        import shutil
        shutil.copyfile(args[1], args[args.index('-output') + 1])
    else:
        print('arm64 x86_64' if os.environ.get('FAKE_UNIVERSAL') else 'arm64')
elif tool == 'xcrun':
    if args[0] == 'swift':
        if '--show-bin-path' in args: print(os.environ['FAKE_BUILD'])
    elif args[0] == 'dsymutil':
        assert '--verify' in args
        if mode == 'generation-failure': sys.exit(1)
        assert '-o' in args and '--output' not in args
        p = pathlib.Path(args[args.index('-o') + 1]) / 'Contents/Resources/DWARF/speak'
        p.parent.mkdir(parents=True)
        data = ('DWARF:' + uuid + ':' + os.environ.get('FAKE_DEBUG_CONTENT', 'same')).encode()
        p.write_bytes(b'' if mode == 'empty-dwarf' else data)
        if mode == 'warning': print('warning: missing object file', file=sys.stderr)
    elif args[0] == 'lipo':
        print('arm64 x86_64' if os.environ.get('FAKE_UNIVERSAL') else 'arm64')
    elif args[0] == 'dwarfdump':
        if '--uuid' in args:
            p = pathlib.Path(args[-1]); symbol = 'DWARF' in str(p)
            value = other if (symbol and mode == 'uuid-mismatch') else uuid
            if not symbol and mode == 'post-strip-mismatch' and b'|stripped' in p.read_bytes():
                value = other
            if mode == 'no-uuids': sys.exit(0)
            print('UUID:', value, '(arm64)', p)
            if os.environ.get('FAKE_UNIVERSAL') and not (symbol and mode == 'missing-slice'):
                print('UUID:', uuid, '(x86_64)', p)
        elif '--verify' in args:
            if mode == 'verification-failure': sys.exit(1)
            if mode == 'verification-warning': print('warning: invalid DWARF', file=sys.stderr)
        elif '--debug-info' in args:
            if mode == 'info-failure': sys.exit(1)
            if mode != 'no-compile-unit' and not (mode == 'empty-second-slice' and '--arch=x86_64' in args):
                print('0x0000000c: DW_TAG_compile_unit')
        else: sys.exit(3)
    else: sys.exit(4)
else: sys.exit(5)
'''


class MacCLISymbolTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="mac-cli-symbols-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.tool = self.root / "fake_tools.py"
        self.tool.write_text(FAKE_TOOL)
        self.binary = self.root / "speak"
        self.binary.write_bytes(b"owned executable")
        self.destination = self.root / "retained/arm64/speak.dSYM"
        self.log = self.root / "calls.jsonl"
        self.bash_env = self.root / "test-only-shell-functions"
        # Bash functions can shadow even an absolute command. No production
        # tool-path override or source rewriting is needed to test the helper.
        self.bash_env.write_text(
            'function xcrun() { "$FAKE_PYTHON" "$FAKE_TOOL" xcrun "$@"; }\n'
            'function codesign() { "$FAKE_PYTHON" "$FAKE_TOOL" codesign "$@"; }\n'
            'function lipo() { "$FAKE_PYTHON" "$FAKE_TOOL" lipo "$@"; }\n'
            'function /usr/bin/strip() { "$FAKE_PYTHON" "$FAKE_TOOL" strip-fake "$@"; }\n')
        self.env = {**os.environ,
                    "BASH_ENV": str(self.bash_env), "FAKE_LOG": str(self.log),
                    "FAKE_PYTHON": sys.executable, "FAKE_TOOL": str(self.tool), "FAKE_MODE": "",
                    "TMPDIR": str(self.root)}

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def bundles(self):
        return sorted(self.destination.parent.glob("*.dSYM"))

    def run_helper(self, mode="", universal=False):
        env = {**self.env, "FAKE_MODE": mode}
        if universal:
            env["FAKE_UNIVERSAL"] = "1"
        return subprocess.run(["/bin/bash", str(PREPARE), str(self.binary), str(self.destination)],
                              env=env, capture_output=True, text=True, timeout=10)

    def assert_refused_before_strip(self, mode, universal=False):
        original = self.binary.read_bytes()
        result = self.run_helper(mode, universal)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.binary.read_bytes(), original)
        self.assertEqual(self.bundles(), [])
        self.assertNotIn("strip-fake", [call[0] for call in self.calls()])
        self.assertEqual(list(self.destination.parent.glob(".cli-symbols.*")), [])

    def test_retains_verified_symbols_before_stripping_and_checks_identity_afterward(self):
        result = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.bundles()), 1)
        self.assertTrue((self.bundles()[0] / "Contents/Resources/DWARF/speak").is_file())
        self.assertEqual(self.binary.read_bytes(), b"owned executable|stripped")
        calls = self.calls()
        strip_index = next(i for i, call in enumerate(calls) if call[0] == "strip-fake")
        self.assertTrue(any("--verify" in call for call in calls[:strip_index]))
        self.assertTrue(any("--debug-info" in call for call in calls[:strip_index]))
        self.assertTrue(any("--uuid" in call for call in calls[strip_index + 1:]))
        self.assertEqual(calls[strip_index][1:], ["-S", str(self.binary)])

    def test_universal_requires_verified_compilation_units_for_both_slices(self):
        self.assertEqual(self.run_helper(universal=True).returncode, 0)
        calls = self.calls()
        for arch in ["arm64", "x86_64"]:
            self.assertTrue(any("--debug-info" in call and "--arch=" + arch in call for call in calls))

    def test_missing_objects_warning_is_failure_even_with_successful_tool_exit(self):
        self.assert_refused_before_strip("warning")

    def test_generation_failure_does_not_strip(self):
        self.assert_refused_before_strip("generation-failure")

    def test_empty_dwarf_does_not_strip(self):
        self.assert_refused_before_strip("empty-dwarf")

    def test_uuid_mismatch_does_not_strip(self):
        self.assert_refused_before_strip("uuid-mismatch")

    def test_missing_universal_slice_does_not_strip(self):
        self.assert_refused_before_strip("missing-slice", universal=True)

    def test_absent_uuid_output_does_not_strip(self):
        self.assert_refused_before_strip("no-uuids")

    def test_dwarf_verification_failure_does_not_strip(self):
        self.assert_refused_before_strip("verification-failure")

    def test_dwarf_verification_warning_does_not_strip(self):
        self.assert_refused_before_strip("verification-warning")

    def test_empty_compilation_units_does_not_strip(self):
        self.assert_refused_before_strip("no-compile-unit")

    def test_second_architecture_empty_compilation_units_does_not_strip(self):
        self.assert_refused_before_strip("empty-second-slice", universal=True)

    def test_dwarf_reader_failure_does_not_strip(self):
        self.assert_refused_before_strip("info-failure")

    def test_strip_failure_retains_verified_symbols_but_reports_failure(self):
        result = self.run_helper("strip-failure")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(self.bundles()), 1)
        self.assertNotIn("Verified and retained", result.stdout)

    def test_changed_uuid_after_strip_reports_failure_with_original_symbols_retained(self):
        self.assertNotEqual(self.run_helper("post-strip-mismatch").returncode, 0)
        self.assertEqual(len(self.bundles()), 1)

    def test_existing_prefix_bundle_is_preserved_while_new_symbols_are_generated(self):
        self.destination.mkdir(parents=True)
        (self.destination / "proof").write_bytes(b"preserve")
        self.assertEqual(self.run_helper().returncode, 0)
        self.assertEqual((self.destination / "proof").read_bytes(), b"preserve")
        self.assertEqual(len(self.bundles()), 2)

    def test_identical_same_uuid_rerun_reuses_bundle_after_fresh_verification(self):
        self.assertEqual(self.run_helper().returncode, 0)
        original = self.bundles()[0]
        before = (original / "Contents/Resources/DWARF/speak").stat().st_mtime_ns
        self.binary.write_bytes(b"owned executable")
        self.assertEqual(self.run_helper().returncode, 0)
        self.assertEqual(self.bundles(), [original])
        self.assertEqual((original / "Contents/Resources/DWARF/speak").stat().st_mtime_ns, before)
        self.assertEqual(sum(call[0] == "strip-fake" for call in self.calls()), 2)
        self.assertEqual(sum("dsymutil" in call for call in self.calls()), 2)

    def test_new_uuid_retains_both_builds(self):
        self.assertEqual(self.run_helper().returncode, 0)
        original = self.bundles()[0]
        self.env["FAKE_UUID"] = "3540060A-29D8-3E14-B054-000E88C279AC"
        self.binary.write_bytes(b"owned executable")
        self.assertEqual(self.run_helper().returncode, 0)
        self.assertEqual(len(self.bundles()), 2)
        self.assertIn(original, self.bundles())

    def test_changed_debug_data_same_uuid_is_retained_and_next_rerun_reuses_it(self):
        self.assertEqual(self.run_helper().returncode, 0)
        original = self.bundles()[0]
        old_bytes = (original / "Contents/Resources/DWARF/speak").read_bytes()
        self.env["FAKE_DEBUG_CONTENT"] = "changed"
        self.binary.write_bytes(b"owned executable")
        self.assertEqual(self.run_helper().returncode, 0)
        both = self.bundles()
        self.assertEqual(len(both), 2)
        self.assertEqual((original / "Contents/Resources/DWARF/speak").read_bytes(), old_bytes)
        self.binary.write_bytes(b"owned executable")
        self.assertEqual(self.run_helper().returncode, 0)
        self.assertEqual(self.bundles(), both)

    def test_symlink_sibling_is_preserved_and_not_reused(self):
        outside = self.root / "outside"
        outside.mkdir()
        (outside / "proof").write_bytes(b"preserve")
        self.destination.parent.mkdir(parents=True)
        sibling = self.destination.parent / "speak-2540060A-29D8-3E14-B054-000E88C279AC.dSYM"
        sibling.symlink_to(outside, target_is_directory=True)
        self.assertEqual(self.run_helper().returncode, 0)
        self.assertTrue(sibling.is_symlink())
        self.assertEqual((outside / "proof").read_bytes(), b"preserve")
        self.assertEqual(sum(not path.is_symlink() for path in self.bundles()), 1)

    def assert_build_refuses_incomplete_symbols(self, train, embedded=False):
        build = self.root / "build"
        build.mkdir()
        shutil.copyfile(self.binary, build / "speak")
        output = self.root / "release-assets"
        argv = ["/bin/bash", str(ROOT / "scripts/build-speak-cli-standalone.sh"),
                "arm64", "1.2.3", str(output), "fake identity"]
        if embedded:
            app = self.root / "owned.app"
            (app / "Contents/MacOS").mkdir(parents=True)
            argv = ["/bin/bash", str(ROOT / "scripts/build-speak-cli.sh"), str(app),
                    "fake identity", "universal", str(output / "symbols")]
        result = subprocess.run(argv,
                                env={**self.env, "FAKE_MODE": "warning", "FAKE_BUILD": str(build),
                                     "TUIST_RELEASE_TRAIN": train,
                                     **({"FAKE_UNIVERSAL": "1"} if embedded else {})},
                                capture_output=True, text=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("incomplete or invalid debug information", result.stderr)
        self.assertTrue(any("dsymutil" in call for call in self.calls()))
        self.assertFalse(list(output.glob("*.zip")))
        self.assertNotIn("codesign", [call[0] for call in self.calls()])
        if embedded:
            self.assertFalse((app / "Contents/MacOS/speak").exists())
            staged_binary = Path(next(call for call in self.calls() if "dsymutil" in call)[3])
            self.assertTrue(staged_binary.is_relative_to(self.root))
            self.assertNotEqual(staged_binary.parent, self.root)
            self.assertFalse(staged_binary.parent.exists())
            self.assertTrue(self.binary.exists())
        swift_calls = [call for call in self.calls() if call[:3] == ["xcrun", "swift", "build"]]
        self.assertEqual(len(swift_calls), 4 if embedded else 2)
        for call in swift_calls:
            self.assertEqual("-DALPHA" in call, train == "alpha")
            self.assertEqual("-Xswiftc" in call, train == "alpha")

    def test_stable_standalone_generation_failure_never_signs_or_archives(self):
        self.assert_build_refuses_incomplete_symbols("stable")

    def test_alpha_standalone_generation_failure_never_signs_or_archives(self):
        self.assert_build_refuses_incomplete_symbols("alpha")

    def test_stable_universal_embedded_generation_failure_never_changes_app(self):
        self.assert_build_refuses_incomplete_symbols("stable", embedded=True)

    def test_alpha_universal_embedded_generation_failure_never_changes_app(self):
        self.assert_build_refuses_incomplete_symbols("alpha", embedded=True)


if __name__ == "__main__":
    unittest.main()
