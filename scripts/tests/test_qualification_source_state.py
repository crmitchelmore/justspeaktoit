"""Real temporary Git checkouts characterize content-free source observations."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


HELPER = Path(__file__).resolve().parents[1] / "qualification_source_state.py"
SPEC = importlib.util.spec_from_file_location("source_state", HELPER)
STATE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(STATE)


class SourceStateTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="qualification-state-")
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.git("init", "-q")
        (self.root / "Sources").mkdir()
        (self.root / "Sources/example.swift").write_bytes(b"let example = 1\n")
        (self.root / "Package.resolved").write_bytes(b'{"pins": []}\n')
        (self.root / ".gitignore").write_text(".build/\n")
        self.git("add", "Sources", "Package.resolved", ".gitignore")
        self.git("-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", "-c", "user.name=Fixture",
                 "-c", "user.email=fixture@example.invalid", "commit", "-qm", "fixture")

    def git(self, *arguments):
        return subprocess.check_output(["git", *arguments], cwd=self.root, stderr=subprocess.DEVNULL)

    def test_clean_snapshot_binds_head_inputs_and_lock_without_reporting_contents(self):
        receipt = STATE.capture(self.root, "before")
        self.assertTrue(receipt["collectionComplete"])
        self.assertFalse(receipt["gitDirty"])
        self.assertEqual(receipt["head"], self.git("rev-parse", "HEAD").decode().strip())
        self.assertEqual(receipt["headInputInventory"]["count"], 2)
        self.assertEqual(receipt["records"], [])
        self.assertTrue(receipt["packageResolved"]["matchesHEADRawBytes"])
        self.assertEqual(receipt["packageResolved"]["sha256"], hashlib.sha256(b'{"pins": []}\n').hexdigest())
        self.assertNotIn('"pins"', json.dumps(receipt))
        self.assertLessEqual(receipt["startedMonotonicNS"], receipt["finishedMonotonicNS"])

    def test_staged_rename_and_worktree_edit_have_distinct_original_index_and_content_hashes(self):
        original_blob = self.git("rev-parse", "HEAD:Sources/example.swift").decode().strip()
        name = "Sources/renamed\n名.swift"
        self.git("mv", "Sources/example.swift", name)
        updated = b"let example = 2\n"
        (self.root / name).write_bytes(updated)
        receipt = STATE.capture(self.root, "after")
        record = next(record for record in receipt["records"] if record["path"] == name)
        self.assertEqual(record["status"], "RM")
        self.assertEqual(record["originalPath"], "Sources/example.swift")
        self.assertEqual(record["originalHeadEntry"]["blob"], original_blob)
        self.assertEqual(record["indexEntries"][0]["blob"], original_blob)
        self.assertEqual(record["worktree"]["sha256"], hashlib.sha256(updated).hexdigest())
        self.assertNotEqual(record["worktree"]["rawGitBlob"], original_blob)
        self.assertTrue(receipt["collectionComplete"])

    def test_untracked_outputs_and_secret_file_names_are_separate_without_reading_their_bytes(self):
        output = self.root / "receipt"
        output.mkdir()
        (output / "tests.log").write_text("owned output")
        secret = b"UNTRACKED-SECRET-SENTINEL"
        (self.root / ".env").write_bytes(secret)
        (self.root / ".build").mkdir()
        (self.root / ".build/ignored").write_text("ignored")
        receipt = STATE.capture(self.root, "after", output)
        records = {item["path"]: item for item in receipt["records"]}
        self.assertTrue(records["receipt/tests.log"]["insideOwnedOutputDirectory"])
        self.assertFalse(records[".env"]["insideOwnedOutputDirectory"])
        self.assertFalse(records[".env"]["tracked"])
        self.assertNotIn("worktree", records[".env"])
        self.assertNotIn(".build/ignored", records)
        self.assertNotIn(secret.decode(), json.dumps(receipt))
        self.assertNotIn(hashlib.sha256(secret).hexdigest(), json.dumps(receipt))

    def test_after_snapshot_detects_changed_source_without_claiming_compiler_read_identity(self):
        before = STATE.capture(self.root, "before")
        updated = b"let example = 42\n"
        (self.root / "Sources/example.swift").write_bytes(updated)
        after = STATE.capture(self.root, "after", command_outcome="failure")
        self.assertFalse(before["gitDirty"])
        self.assertTrue(after["gitDirty"])
        self.assertEqual(before["head"], after["head"])
        self.assertEqual(after["commandOutcome"], "failure")
        self.assertEqual(after["records"][0]["worktree"]["sha256"], hashlib.sha256(updated).hexdigest())
        self.assertLess(before["finishedMonotonicNS"], after["startedMonotonicNS"])
        self.assertIn("not compiled-product binding", " ".join(after["limitations"]))

    def test_predeleted_restored_and_untracked_lock_states_are_not_equated(self):
        lock = self.root / "Package.resolved"
        original = lock.read_bytes()
        lock.unlink()
        absent = STATE.capture(self.root, "initially-absent")
        self.assertEqual(absent["packageResolved"]["kind"], "missing")
        self.assertEqual(absent["records"][0]["status"], " D")
        self.assertIsNone(absent["packageResolved"]["matchesHEADRawBytes"])
        lock.write_bytes(original)
        restored = STATE.capture(self.root, "after-restore")
        self.assertTrue(restored["packageResolved"]["matchesHEADRawBytes"])
        self.git("rm", "--cached", "-q", "Package.resolved")
        self.git("-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", "-c", "user.name=Fixture",
                 "-c", "user.email=fixture@example.invalid", "commit", "-qm", "untrack lock")
        untracked = STATE.capture(self.root, "untracked")
        self.assertEqual(untracked["packageResolved"]["kind"], "regular")
        self.assertTrue(untracked["packageResolved"]["contentsNotRead"])
        self.assertNotIn("sha256", untracked["packageResolved"])

    def test_symlink_is_not_followed_and_incomplete_collection_is_never_clean_proof(self):
        path = self.root / "Sources/example.swift"
        path.unlink()
        path.symlink_to(self.root / "Package.resolved")
        receipt = STATE.capture(self.root, "symlink")
        self.assertEqual(receipt["records"][0]["worktree"]["kind"], "symlink")
        self.assertNotIn("sha256", receipt["records"][0]["worktree"])
        with patch.object(STATE, "MAX_HASH_BYTES", 1):
            limited = STATE.capture(self.root, "bounded")
        self.assertFalse(limited["collectionComplete"])
        self.assertIn("incomplete-or-changing-worktree-hash", limited["collectionErrors"])
        with tempfile.TemporaryDirectory() as other:
            unavailable = STATE.capture(Path(other), "not-repository")
        self.assertFalse(unavailable["collectionComplete"])
        self.assertIsNone(unavailable["head"])
        self.assertIsNone(unavailable["gitDirty"])

    def test_unreadable_hash_retains_path_and_record_truncation_is_explicit(self):
        (self.root / "Sources/example.swift").write_text("changed")
        real_open = os.open

        def deny_source(path, *args, **kwargs):
            if path == self.root / "Sources/example.swift":
                raise PermissionError("PRIVATE-SENTINEL")
            return real_open(path, *args, **kwargs)

        with patch.object(STATE.os, "open", side_effect=deny_source):
            receipt = STATE.capture(self.root, "unreadable")
        self.assertFalse(receipt["collectionComplete"])
        self.assertEqual(receipt["records"][0]["path"], "Sources/example.swift")
        self.assertEqual(receipt["records"][0]["worktree"]["hashUnavailable"], "PermissionError")
        self.assertNotIn("PRIVATE-SENTINEL", json.dumps(receipt))
        (self.root / "other").write_text("untracked")
        with patch.object(STATE, "MAX_RECORDS", 1):
            limited = STATE.capture(self.root, "limited")
        self.assertEqual(limited["totalRecords"], 2)
        self.assertTrue(limited["recordsTruncated"])
        self.assertFalse(limited["collectionComplete"])

    def test_cli_keeps_failed_collection_advisory_and_never_overwrites_a_receipt(self):
        output = self.root / "existing.json"
        output.write_text("preserve existing")
        with tempfile.TemporaryDirectory() as other:
            result = subprocess.run([sys.executable, "-B", str(HELPER), "--phase", "after",
                                     "--command-outcome", "skipped", "--output", str(output)],
                                    cwd=other, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0)
        printed = json.loads(result.stdout)
        self.assertFalse(printed["collectionComplete"])
        self.assertIn("write-FileExistsError", printed["collectionErrors"])
        self.assertEqual(output.read_text(), "preserve existing")


if __name__ == "__main__":
    unittest.main()
