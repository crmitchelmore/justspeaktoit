import importlib.util
import pathlib
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("linux_stage", ROOT / "scripts/stage-linux-desktop.py")
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

    def test_missing_cli_fails_before_output_is_created(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = pathlib.Path(scratch)
            binary = self.fixture(root)
            output = root / "layout"
            with self.assertRaisesRegex(ValueError, "speak executable"):
                STAGE.stage(binary, output, cli=root / "absent")
            self.assertFalse(output.exists())

    def test_flatpak_explicitly_builds_and_stages_the_cli(self):
        manifest = (ROOT / "packaging/linux/com.justspeaktoit.JustSpeakToIt.yml").read_text()
        self.assertIn("--product speak --static-swift-stdlib", manifest)
        self.assertIn("--cli .build/release/speak", manifest)

    def test_linux_workflow_triggers_for_each_automation_surface_on_both_events(self):
        lines = (ROOT / ".github/workflows/linux.yml").read_text().splitlines()
        paths = (
            "Sources/CLinuxAutomation/**", "Sources/SpeakLinuxAutomation/**",
            "Sources/SpeakAutomationKit/**", "Sources/SpeakCLI/**",
            "Tests/SpeakLinuxAutomationTests/**", "Tests/SpeakAutomationKitTests/**",
            "scripts/tests/test_linux_automation_staging.py",
        )
        for event in ("push", "pull_request"):
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
