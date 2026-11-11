import importlib.util
import json
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "ci" / "affected-swift-tests.py"
spec = importlib.util.spec_from_file_location("affected_swift_tests", SCRIPT)
affected = importlib.util.module_from_spec(spec)
spec.loader.exec_module(affected)


def target(name, kind="regular", deps=(), path=None):
    return {"name": name, "type": kind, "path": path,
            "dependencies": [{"byName": [dep, None]} for dep in deps]}


PACKAGE = {"targets": [
    target("SpeakCore"),
    target("SpeakSync", deps=["SpeakCore"]),
    target("SpeakApp", "executable", deps=["SpeakCore", "SpeakSync"]),
    target("SpeakiOSLib", deps=["SpeakCore"], path="Sources/SpeakiOS"),
    target("SpeakCoreTests", "test", deps=["SpeakCore"]),
    target("SpeakSyncTests", "test", deps=["SpeakSync"]),
    target("SpeakAppTests", "test", deps=["SpeakApp"]),
    target("SpeakiOSTests", "test", deps=["SpeakiOSLib"]),
    target("SpeakDesktopTests", "test", deps=["SpeakCore"]),
]}


class SelectionTests(unittest.TestCase):
    def test_a_leaf_change_selects_only_its_dependants(self):
        self.assertEqual(affected.select(["Sources/SpeakApp/View.swift"], PACKAGE, set()),
                         ("filtered", ["SpeakAppTests"]))
        self.assertEqual(affected.select(["Sources/SpeakiOS/Screen.swift"], PACKAGE, set()),
                         ("filtered", ["SpeakiOSTests"]))

    def test_a_shared_change_selects_every_transitive_dependant(self):
        mode, selected = affected.select(["Sources/SpeakSync/Store.swift"], PACKAGE, set())
        self.assertEqual((mode, selected), ("filtered", ["SpeakAppTests", "SpeakSyncTests"]))
        mode, selected = affected.select(["Sources/SpeakCore/Model.swift"], PACKAGE, {"SpeakDesktopTests"})
        self.assertEqual(selected, ["SpeakAppTests", "SpeakCoreTests", "SpeakSyncTests", "SpeakiOSTests"])

    def test_a_test_file_selects_its_own_target(self):
        self.assertEqual(affected.select(["Tests/SpeakCoreTests/ModelTests.swift"], PACKAGE, set()),
                         ("filtered", ["SpeakCoreTests"]))

    def test_manifest_support_and_unmapped_sources_select_everything(self):
        for path in ("Package.swift", "Tests/SpeakTestSupport/Fake.swift", "Sources/Unknown/File.swift",
                     ".github/workflows/ci.yml", ".github/workflows/ci-macos-debug.yml"):
            mode, selected = affected.select([path], PACKAGE, {"SpeakDesktopTests"})
            self.assertEqual(mode, "all", path)
            self.assertNotIn("SpeakDesktopTests", selected)

    def test_non_swift_changes_select_nothing(self):
        self.assertEqual(affected.select(["Docs/readme.md", "scripts/tool.py"], PACKAGE, set()), ("none", []))

    def test_skipped_targets_never_run_on_the_pull_request(self):
        self.assertEqual(affected.select(["Tests/SpeakDesktopTests/A.swift"], PACKAGE, {"SpeakDesktopTests"}),
                         ("none", []))


class MainTests(unittest.TestCase):
    def test_an_unresolvable_base_runs_every_test_target(self):
        import contextlib
        import io
        import subprocess
        from unittest import mock

        def fake_run(command, **kwargs):
            if command[:2] == ["git", "diff"]:
                return subprocess.CompletedProcess(command, 128, "", "fatal: no merge base")
            return subprocess.CompletedProcess(command, 0, json.dumps(PACKAGE), "")

        out = io.StringIO()
        with mock.patch.object(affected.subprocess, "run", fake_run), \
                mock.patch.object(affected.sys, "argv", ["x", "origin/main", "--skip-target", "SpeakDesktopTests"]), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(affected.main(), 0)
        self.assertIn("mode=all", out.getvalue())
        self.assertIn("skip=^(SpeakDesktopTests)\\.", out.getvalue())


class ShallowCloneTests(unittest.TestCase):
    def git(self, cwd, *args):
        import subprocess
        return subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@t", *args], cwd=cwd, check=True,
                              capture_output=True, text=True).stdout.strip()

    def test_a_shallow_merge_commit_diffs_against_the_fetched_base(self):
        import os
        import tempfile
        with tempfile.TemporaryDirectory() as root:
            origin = os.path.join(root, "origin")
            os.makedirs(os.path.join(origin, "Sources/SpeakApp"))
            self.git(root, "init", "-q", "-b", "main", origin)
            for index in range(3):
                with open(os.path.join(origin, "Sources/SpeakApp/Base.swift"), "a") as handle:
                    handle.write(f"// {index}\n")
                self.git(origin, "add", "-A")
                self.git(origin, "commit", "-qm", f"base {index}")
            base = self.git(origin, "rev-parse", "HEAD")
            self.git(origin, "checkout", "-qb", "feature")
            with open(os.path.join(origin, "Sources/SpeakApp/Feature.swift"), "w") as handle:
                handle.write("// feature\n")
            self.git(origin, "add", "-A")
            self.git(origin, "commit", "-qm", "feature")
            clone = os.path.join(root, "clone")
            self.git(root, "clone", "-q", "--depth=1", "--branch", "feature", f"file://{origin}", clone)
            previous = os.getcwd()
            os.chdir(clone)
            try:
                self.assertIsNone(affected.changed_files(base), "unfetched base fails safe")
                self.git(clone, "fetch", "--no-tags", "--depth=1", "origin", base)
                self.assertEqual(affected.changed_files(base), ["Sources/SpeakApp/Feature.swift"])
            finally:
                os.chdir(previous)


if __name__ == "__main__":
    unittest.main()
