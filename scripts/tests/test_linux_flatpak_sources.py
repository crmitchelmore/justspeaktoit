"""Regression checks for the Flatpak's pinned offline SwiftPM mirror setup."""
import json
import os
import runpy
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

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


QUALIFICATION = runpy.run_path(str(ROOT / 'scripts/linux-flatpak-qualification.py'))


class QualificationPreconditionsTests(unittest.TestCase):
    def source(self):
        return {'head_sha': '1' * 40, 'head_repository': {'full_name': 'owner/repo'},
                'repository': {'id': 123}, 'path': '.github/workflows/linux-flatpak.yml',
                'status': 'completed', 'conclusion': 'success', 'event': 'push', 'pull_requests': []}

    def test_successful_source_run(self):
        metadata = QUALIFICATION['source_metadata'](self.source(), '1' * 40, 'owner/repo', '1', '2' * 40)
        self.assertEqual(metadata['sourceSHA'], '1' * 40)

    def test_failed_cancelled_or_incomplete_source_is_refused(self):
        for status, conclusion in [('completed', 'failure'), ('completed', 'cancelled'),
                                  ('in_progress', None), ('completed', 'skipped')]:
            run = dict(self.source(), status=status, conclusion=conclusion)
            with self.subTest(status=status, conclusion=conclusion), self.assertRaises(ValueError):
                QUALIFICATION['source_metadata'](run, '1' * 40, 'owner/repo', '1', '2' * 40)

    def test_wrong_run_identity_is_refused(self):
        for change in [{'head_sha': '3' * 40}, {'head_repository': {'full_name': 'other/repo'}},
                       {'path': '.github/workflows/other.yml'}]:
            with self.subTest(change=change), self.assertRaises(ValueError):
                QUALIFICATION['source_metadata'](dict(self.source(), **change), '1' * 40, 'owner/repo', '1', '2' * 40)

    def test_invalid_app_id_cannot_change_overrides(self):
        with mock.patch('subprocess.run') as run, self.assertRaises(ValueError):
            QUALIFICATION['check_overrides']('--reset')
        run.assert_not_called()

    def test_all_override_scopes_are_read_only_and_empty(self):
        with mock.patch('subprocess.run', return_value=subprocess.CompletedProcess([], 0, '', '')) as run:
            QUALIFICATION['check_overrides']('com.justspeaktoit.JustSpeakToIt')
        self.assertEqual([call.args[0] for call in run.call_args_list], [
            ['flatpak', 'override', scope, '--show', *target]
            for scope in ('--user', '--system') for target in ([], ['com.justspeaktoit.JustSpeakToIt'])])

    def test_each_override_scope_or_read_failure_is_refused_without_values(self):
        for position in range(4):
            for code, output in [(0, '[Environment]\nPRIVATE_VALUE=hidden\n'), (1, '')]:
                results = [subprocess.CompletedProcess([], 0, '', '') for _ in range(position)]
                results.append(subprocess.CompletedProcess([], code, output, 'private diagnostic'))
                with self.subTest(position=position, code=code), mock.patch('subprocess.run', side_effect=results), \
                        self.assertRaises(ValueError) as error:
                    QUALIFICATION['check_overrides']('com.justspeaktoit.JustSpeakToIt')
                self.assertNotIn('hidden', str(error.exception))
                self.assertNotIn('private diagnostic', str(error.exception))


if __name__ == '__main__':
    unittest.main()
