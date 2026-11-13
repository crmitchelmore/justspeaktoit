"""Tests for scripts/ci/sync-tree.py, which keeps linux-precheck's container build incremental."""
import importlib.machinery
import importlib.util
import os
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
_loader = importlib.machinery.SourceFileLoader('sync_tree', str(ROOT / 'scripts' / 'ci' / 'sync-tree.py'))
_spec = importlib.util.spec_from_loader('sync_tree', _loader)
sync_tree = importlib.util.module_from_spec(_spec)
_loader.exec_module(sync_tree)


class SyncTreeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.src, self.dst = Path(self.tmp.name, 'src'), Path(self.tmp.name, 'dst')
        (self.src / 'Sources').mkdir(parents=True)
        (self.src / 'Sources' / 'same.swift').write_text('let a = 1\n')
        (self.src / 'Sources' / 'edited.swift').write_text('let b = 1\n')
        (self.src / 'tool.sh').write_text('#!/bin/sh\n')
        sync_tree.sync(self.src, self.dst, set())

    def tearDown(self):
        self.tmp.cleanup()

    def test_only_changed_files_are_rewritten_and_extras_removed(self):
        same, edited = self.dst / 'Sources' / 'same.swift', self.dst / 'Sources' / 'edited.swift'
        os.utime(same, (1_000_000, 1_000_000))
        before = same.stat()
        (self.src / 'Sources' / 'edited.swift').write_text('let b = 22\n')
        (self.src / 'tool.sh').unlink()
        (self.src / 'Sources' / 'Old').mkdir()
        (self.dst / 'stale.swift').write_text('gone\n')
        (self.dst / 'Sources' / 'Gone').mkdir()
        (self.dst / 'Sources' / 'Gone' / 'x.swift').write_text('gone\n')

        written, removed = sync_tree.sync(self.src, self.dst, set())

        self.assertEqual((written, removed), (1, 4))
        self.assertEqual((same.stat().st_mtime, same.stat().st_ino), (before.st_mtime, before.st_ino))
        self.assertEqual(edited.read_text(), 'let b = 22\n')
        self.assertFalse((self.dst / 'tool.sh').exists())
        self.assertFalse((self.dst / 'stale.swift').exists())
        self.assertFalse((self.dst / 'Sources' / 'Gone').exists())
        self.assertTrue((self.dst / 'Sources' / 'Old').is_dir())

    def test_mode_changes_and_symlinks_are_mirrored(self):
        os.chmod(self.src / 'tool.sh', 0o755)
        (self.src / 'link').symlink_to('tool.sh')
        sync_tree.sync(self.src, self.dst, set())
        self.assertTrue(os.access(self.dst / 'tool.sh', os.X_OK))
        self.assertEqual(os.readlink(self.dst / 'link'), 'tool.sh')

    def test_excluded_top_level_entries_are_left_alone(self):
        (self.dst / '.build').mkdir()
        (self.dst / '.build' / 'product').write_text('warm\n')
        sync_tree.sync(self.src, self.dst, {'.build'})
        self.assertEqual((self.dst / '.build' / 'product').read_text(), 'warm\n')


if __name__ == '__main__':
    unittest.main()
