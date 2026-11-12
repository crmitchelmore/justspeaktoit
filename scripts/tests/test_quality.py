"""Tests for scripts/quality's file ownership: which tool sees which file."""
import importlib.machinery
import importlib.util
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
_loader = importlib.machinery.SourceFileLoader('jsti_quality', str(ROOT / 'scripts' / 'quality'))
_spec = importlib.util.spec_from_loader('jsti_quality', _loader)
quality = importlib.util.module_from_spec(_spec)
_loader.exec_module(quality)


class ClassifyTests(unittest.TestCase):
    def classify(self, files: dict[str, str]):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name, text in files.items():
                (root / name).parent.mkdir(parents=True, exist_ok=True)
                (root / name).write_text(text, encoding='utf-8')
            with mock.patch.object(quality, 'ROOT', root):
                return quality.classify([*files, 'deleted.py'])

    def test_extensionless_scripts_are_owned_by_their_shebang(self):
        groups = self.classify({
            'scripts/pre-pr': '#!/usr/bin/env python3\n',
            'scripts/install-hook': '#!/usr/bin/env bash\n',
            'scripts/legacy': '#!/bin/sh\n',
            'scripts/notes': 'plain text\n',
            'scripts/release.mjs': '#!/usr/bin/env node\n',
        })
        self.assertEqual(groups['python'], ['scripts/pre-pr'])
        self.assertEqual(groups['shell'], ['scripts/install-hook', 'scripts/legacy'])

    def test_vendored_generated_and_deleted_files_are_skipped(self):
        groups = self.classify({
            'Sources/A.swift': '', '.build/x/B.swift': '', 'android/app/c.py': '',
            'workers/paid-access/node_modules/x/d.ts': '', 'workers/paid-access/src/e.ts': '',
            '.github/workflows/ci.yml': '', '.github/actions/setup/action.yml': '',
        })
        self.assertEqual(groups['swift'], ['Sources/A.swift'])
        self.assertEqual(groups['python'], [])
        self.assertEqual(groups['worker'], ['workers/paid-access/src/e.ts'])
        self.assertEqual(groups['workflows'], ['.github/workflows/ci.yml'])


if __name__ == '__main__':
    unittest.main()
