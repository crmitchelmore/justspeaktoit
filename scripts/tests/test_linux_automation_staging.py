import importlib.util
import pathlib
import tempfile
import unittest
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("linux_stage", ROOT / "scripts/linux/stage-linux-desktop.py")
STAGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(STAGE)


class LinuxAutomationStagingTests(unittest.TestCase):
    def fixture(self, root):
        binary = root / "SpeakLinux"
        binary.write_bytes(b"synthetic app")
        (root / "SpeakApp_SpeakCore.resources").mkdir()
        theme = root / "SpeakApp_SpeakLinux.resources/hicolor"
        theme.mkdir(parents=True)
        (theme / "index.theme").write_text("synthetic theme")
        return binary

    def test_explicit_cli_is_staged_as_executable_without_installing(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = pathlib.Path(scratch)
            binary = self.fixture(root)
            cli = root / "speak"
            cli.write_bytes(b"synthetic CLI")
            output = root / "layout"
            STAGE.stage(binary, output, cli=cli)
            self.assertEqual((output / "bin/speak").read_bytes(), cli.read_bytes())
            self.assertTrue((output / "bin/speak").stat().st_mode & 0o111)

    def test_duplicate_optional_bundle_is_rejected_before_writing(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = pathlib.Path(scratch)
            binary = self.fixture(root)
            for suffix in (".bundle", ".resources"):
                (root / ("SpeakApp_SpeakFeedbackResources" + suffix)).mkdir()
            output = root / "layout"
            with self.assertRaisesRegex(ValueError, "duplicate production resource bundle target"):
                STAGE.stage(binary, output)
            self.assertFalse(output.exists())

    def test_missing_cli_fails_before_output_is_created(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = pathlib.Path(scratch)
            binary = self.fixture(root)
            output = root / "layout"
            with self.assertRaisesRegex(ValueError, "speak executable"):
                STAGE.stage(binary, output, cli=root / "absent")
            self.assertFalse(output.exists())

    def test_test_support_is_excluded_only_from_production_layout(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = pathlib.Path(scratch)
            binary = self.fixture(root)
            for name in ("SpeakTestSupport", "SpeakApp_SpeakTestSupport", "SpeakApp_SpeakTestSupportTools"):
                directory = root / (name + ".resources")
                directory.mkdir()
                (directory / "fixture.json").write_bytes(b"fixture bytes")
            output = root / "layout"
            STAGE.stage(binary, output)
            for name in ("SpeakTestSupport", "SpeakApp_SpeakTestSupport"):
                self.assertFalse((output / "bin" / (name + ".resources")).exists())
                self.assertEqual((root / (name + ".resources") / "fixture.json").read_bytes(), b"fixture bytes")
            self.assertEqual((output / "bin/SpeakApp_SpeakTestSupportTools.resources/fixture.json").read_bytes(),
                             b"fixture bytes")

    def test_swift64_bundle_resources_are_preserved(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = pathlib.Path(scratch)
            binary = self.fixture(root)
            for directory in root.glob("*.resources"):
                directory.rename(directory.with_suffix(".bundle"))
            test_bundle = root / "SpeakApp_SpeakCoreTests.bundle"
            test_bundle.mkdir()
            output = root / "layout"
            STAGE.stage(binary, output)
            self.assertTrue((output / "bin/SpeakApp_SpeakCore.bundle").is_dir())
            self.assertTrue((output / "bin/SpeakApp_SpeakLinux.bundle/hicolor/index.theme").is_file())
            self.assertFalse((output / "bin" / test_bundle.name).exists())

    def test_shared_runtime_closure_deduplicates_transitive_dependencies(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = pathlib.Path(scratch)
            for name in ("app", "cli", "libswiftCore.so", "libFoundation.so", "unused.so"):
                (root / name).write_bytes(b"fixture")
            dependencies = {
                "app": ["libFoundation.so", "libc.so.6"], "cli": ["libswiftCore.so"],
                "libFoundation.so": ["libswiftCore.so"], "libswiftCore.so": ["libc.so.6"],
            }
            def readelf(command, **kwargs):
                return "\n".join("(NEEDED) Shared library: [" + name + "]"
                                 for name in dependencies[pathlib.Path(command[-1]).name])
            with patch.object(STAGE.subprocess, "check_output", side_effect=readelf):
                result = STAGE.swift_runtime_closure([root / "app", root / "cli"], root)
            self.assertEqual(set(result), {"libFoundation.so", "libswiftCore.so"})

    def test_runtime_refuses_missing_swift_libraries_and_escaping_symlinks(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = pathlib.Path(scratch)
            sdk = root / "sdk"
            sdk.mkdir()
            with patch.object(STAGE.subprocess, "check_output",
                              return_value="(NEEDED) Shared library: [libswiftCore.so]"):
                with self.assertRaisesRegex(ValueError, "missing Swift SDK"):
                    STAGE.swift_runtime_closure([root / "app"], sdk)
                outside = root / "external.so"
                outside.write_bytes(b"fixture")
                (sdk / "libswiftCore.so").symlink_to(outside)
                with self.assertRaisesRegex(ValueError, "escapes"):
                    STAGE.swift_runtime_closure([root / "app"], sdk)

    def test_flatpak_explicitly_builds_and_stages_the_cli(self):
        manifest = (ROOT / "packaging/linux/com.justspeaktoit.JustSpeakToIt.yml").read_text()
        self.assertIn("--product speak --disable-sandbox", manifest)
        self.assertNotIn("--static-swift-stdlib", manifest)
        self.assertIn("--swift-runtime", manifest)
        self.assertIn("--cli .build/release/speak", manifest)

    def test_linux_workflow_triggers_for_each_automation_surface_on_both_events(self):
        lines = (ROOT / ".github/workflows/linux.yml").read_text().splitlines()
        paths = (
            "Sources/CLinuxAutomation/**", "Sources/SpeakLinuxAutomation/**",
            "Sources/SpeakAutomationKit/**", "Sources/SpeakCLI/**",
            "Tests/SpeakLinuxAutomationTests/**", "Tests/SpeakAutomationKitTests/**",
            "scripts/tests/test_linux_automation_staging.py",
        )
        self.assertNotIn("  pull_request:", lines)
        for event in ("push",):
            start = lines.index(f"  {event}:") + 1
            end = next((index for index in range(start, len(lines))
                        if lines[index].strip() and not lines[index].startswith("    ")
                        and not lines[index].lstrip().startswith("#")), len(lines))
            for path in paths:
                with self.subTest(event=event, path=path):
                    self.assertIn(f"      - {path}", lines[start:end])

    def linux_step_commands(self, name):
        lines = (ROOT / ".github/workflows/linux.yml").read_text().splitlines()
        job_start = lines.index("  linux-desktop:") + 1
        job_end = next((index for index in range(job_start, len(lines))
                        if lines[index].strip() and not lines[index].startswith("    ")
                        and not lines[index].lstrip().startswith("#")), len(lines))
        steps_start = lines.index("    steps:", job_start, job_end) + 1
        start = lines.index(f"      - name: {name}", steps_start, job_end) + 1
        end = next((index for index in range(start, job_end)
                    if lines[index].startswith("      - ")), job_end)
        step = lines[start:end]
        self.assertFalse(any(line.startswith("        if:") for line in step),
                         "The required build/test step must not be conditional")
        run = next(index for index, line in enumerate(step) if line.startswith("        run:"))
        command = step[run].split("run:", 1)[1].strip()
        if command != "|":
            return [command]
        return [line[10:] for line in step[run + 1:]
                if line.startswith("          ") and line.strip() and not line.lstrip().startswith("#")]

    def test_linux_native_job_builds_pinned_release_cli_and_runs_staging_unit(self):
        build = self.linux_step_commands("Build the Linux app")
        cli = "swift build --configuration release --product speak --jobs 4 --force-resolved-versions"
        self.assertIn(cli, build)
        pin_check = "cmp packaging/linux/Package.resolved Package.resolved"
        self.assertIn(pin_check, build)
        self.assertLess(build.index(cli), build.index(pin_check))
        self.assertEqual(self.linux_step_commands("Test Linux automation staging"), [
            "python3 -B -m unittest discover -s scripts/tests -p test_linux_automation_staging.py"
        ])


if __name__ == "__main__":
    unittest.main()
