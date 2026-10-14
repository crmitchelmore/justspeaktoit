"""Check CI retention of explicit MakeAppx logs, without Windows or a YAML dependency."""
import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]


class PackDiagnosticWiringTests(unittest.TestCase):
    def test_pack_failure_guard_is_used_before_verification(self):
        source = (ROOT / "scripts/windows-package/pack-windows-package.ps1").read_text(encoding="utf-8")
        guard = source.index("Assert-JstiMakeAppxPackSucceeded -Result $pack -LogPath $log")
        self.assertLess(guard, source.index("$evidencePath ="))

    def test_all_pack_jobs_always_retain_only_explicit_pack_logs(self):
        cases = [
            ("windows-cross-proof.yml", "Upload MakeAppx pack diagnostics",
             ["${{ runner.temp }}/package-base/*.pack.log", "${{ runner.temp }}/package-upgrade/*.pack.log"]),
            ("windows-cross-proof.yml", "Upload signed-job MakeAppx pack diagnostics",
             ["${{ runner.temp }}/package-signed/*.pack.log"]),
            ("windows-arm64.yml", "Upload MakeAppx pack diagnostics",
             ["${{ runner.temp }}/package-base/*.pack.log", "${{ runner.temp }}/package-upgrade/*.pack.log"]),
        ]
        for workflow, name, paths in cases:
            with self.subTest(workflow=workflow, step=name):
                source = (ROOT / ".github/workflows" / workflow).read_text(encoding="utf-8")
                step = source.split("      - name: " + name + "\n", 1)[1].split("\n      - ", 1)[0]
                self.assertIn("if: always()", step)
                self.assertIn("if-no-files-found: warn", step)
                retained = step.split("path: |\n", 1)[1].split("if-no-files-found:", 1)[0]
                self.assertEqual([line.strip() for line in retained.splitlines() if line.strip()], paths)

    def test_both_native_package_jobs_run_failure_fixtures(self):
        for workflow in ("windows-cross-proof.yml", "windows-arm64.yml"):
            with self.subTest(workflow=workflow):
                source = (ROOT / ".github/workflows" / workflow).read_text(encoding="utf-8")
                self.assertIn("./scripts/windows-package/test-pack-diagnostics.ps1", source)


if __name__ == "__main__":
    unittest.main()
