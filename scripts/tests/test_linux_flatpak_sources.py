"""Regression checks for the Flatpak's pinned offline SwiftPM mirror setup."""
import json
import os
import runpy
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SETUP = ROOT / 'packaging/linux/swiftpm-offline-setup.sh'


class OfflineMirrorTests(unittest.TestCase):
    def test_reordered_json_fields_keep_identity_and_location_together(self):
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            (root / 'Package.swift').write_text('// test package\n')
            package = root / 'packaging/linux'
            package.mkdir(parents=True)
            # Deliberately put location before identity; these are object fields.
            pins = {'version': 2, 'pins': [
                {'location': 'https://example.com/swift-one.git', 'identity': 'swift-one'},
                {'identity': 'swift-two', 'location': 'https://example.com/swift-two.git'},
            ]}
            (package / 'Package.resolved').write_text(json.dumps(pins, indent=2))
            deps = root / 'deps'
            for pin in pins['pins']:
                (deps / pin['identity'] / '.git').mkdir(parents=True)
            tools = root / 'tools'
            tools.mkdir()
            swift = tools / 'swift'
            swift.write_text('#!/usr/bin/env python3\nimport json,os,sys\n'
                             'with open(os.environ["MIRROR_LOG"], "a") as log:\n'
                             '    log.write(json.dumps(sys.argv[1:])+"\\n")\n')
            swift.chmod(0o755)
            log = root / 'mirrors.jsonl'
            env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ['PATH'], MIRROR_LOG=str(log))
            subprocess.run(['sh', str(SETUP), str(deps)], cwd=root, env=env, check=True,
                           capture_output=True, text=True)
            actual = [json.loads(line) for line in log.read_text().splitlines()]
            expected = [['package', 'config', 'set-mirror', '--original', pin['location'],
                         '--mirror', str(deps / pin['identity'])] for pin in pins['pins']]
            self.assertEqual(actual, expected)
            self.assertEqual(json.loads((root / 'Package.resolved').read_text()), pins)

    def test_missing_checkout_refuses_before_creating_mirror(self):
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            (root / 'Package.swift').write_text('// test package\n')
            package = root / 'packaging/linux'
            package.mkdir(parents=True)
            (package / 'Package.resolved').write_text(json.dumps({'version': 2, 'pins': [
                {'identity': 'missing', 'location': 'https://example.com/missing.git'},
            ]}))
            result = subprocess.run(['sh', str(SETUP), str(root / 'deps')], cwd=root,
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('missing checkout for missing', result.stderr)


class BuildRevisionTests(unittest.TestCase):
    verify = staticmethod(runpy.run_path(str(ROOT / 'packaging/linux/verify_build_revision.py'))['verify_revision'])
    source = '1' * 40
    base = '2' * 40
    built = '3' * 40

    def metadata(self, event='pull_request'):
        return {'sourceSHA': self.source, 'event': event, 'pullRequestParents': [{'baseSHA': self.base}]}

    def test_exact_requested_source(self):
        self.verify(self.source, [], self.metadata('workflow_dispatch'))

    def test_authenticated_pr_merge_parents(self):
        self.verify(self.built, [self.base, self.source], self.metadata())

    def test_unrelated_revisions_and_unverified_merges_are_refused(self):
        for parents, metadata in [([], self.metadata()), ([self.base], self.metadata()),
            ([self.source, self.base], self.metadata()), (['4' * 40, self.source], self.metadata()),
            ([self.base, '4' * 40], self.metadata()), ([self.base, self.source], self.metadata('push')),
            ([self.base, self.source], {'sourceSHA': self.source, 'event': 'pull_request'})]:
            with self.subTest(parents=parents, metadata=metadata), self.assertRaises(ValueError):
                self.verify(self.built, parents, metadata)


if __name__ == '__main__':
    unittest.main()
