"""Regression checks for the Flatpak's pinned offline SwiftPM mirror setup."""
import hashlib
import contextlib
import copy
import io
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
    digest = '4' * 64

    def metadata(self, event='pull_request'):
        return {'runID': '7', 'runAttempt': 2, 'repository': 'owner/repo', 'repositoryID': 123,
                'workflow': '.github/workflows/linux-flatpak.yml', 'sourceSHA': self.source, 'event': event}

    def record(self, event='pull_request', built=None, parents=None):
        request = {'number': 9, 'headSHA': self.source, 'baseSHA': self.base,
                   'headRepositoryID': 123, 'baseRepositoryID': 123} if event == 'pull_request' else None
        return dict(self.metadata(event), version=1, builtRevision=built or self.built,
                    parents=parents if parents is not None else [self.base, self.source],
                    bundleSHA256=self.digest, pullRequest=request)

    def test_exact_requested_source_still_requires_consistent_record_and_parents(self):
        for event in ('push', 'workflow_dispatch', 'pull_request'):
            parents = ['5' * 40]
            record = self.record(event, self.source, parents)
            self.verify(self.source, parents, self.metadata(event), record, self.digest)
            with self.assertRaises(ValueError):
                self.verify(self.source, [], self.metadata(event), record, self.digest)

    def test_authenticated_pr_merge_parents(self):
        self.verify(self.built, [self.base, self.source], self.metadata(), self.record(), self.digest)

    def test_missing_legacy_or_unknown_record_cannot_qualify_even_exact_source(self):
        for record in (None, {}, dict(self.record(), version=2), dict(self.record(), version=True)):
            with self.subTest(record=record), self.assertRaises(ValueError):
                self.verify(self.source, [], self.metadata(), record, self.digest)

    def test_every_authenticated_identity_field_and_attempt_is_bound(self):
        for key, value in [('runID', '8'), ('runAttempt', 1), ('runAttempt', True),
                           ('repository', 'other/repo'), ('repositoryID', 124), ('repositoryID', True),
                           ('workflow', '.github/workflows/other.yml'), ('event', 'push'),
                           ('sourceSHA', '6' * 40)]:
            record = dict(self.record(), **{key: value})
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                self.verify(self.built, [self.base, self.source], self.metadata(), record, self.digest)

    def test_unrelated_revisions_parent_order_and_bundle_tampering_are_refused(self):
        for built, parents, digest in [(self.built, [], self.digest), (self.built, [self.base], self.digest),
            (self.built, [self.source, self.base], self.digest), (self.built, ['4' * 40, self.source], self.digest),
            (self.built, [self.base, '4' * 40], self.digest), ('5' * 40, [self.base, self.source], self.digest),
            (self.built, [self.base, self.source], '5' * 64)]:
            with self.subTest(built=built, parents=parents, digest=digest), self.assertRaises(ValueError):
                self.verify(built, parents, self.metadata(), self.record(), digest)
        # A self-consistent invented checkout/parents pair still cannot replace
        # the recorded PR's exact ordered base + authenticated source relationship.
        for parents in ([self.source, self.base], ['4' * 40, self.source], [self.base, self.source, '5' * 40]):
            with self.subTest(parents=parents), self.assertRaises(ValueError):
                self.verify(self.built, parents, self.metadata(), self.record(parents=parents), self.digest)

    def test_same_repository_pr_identities_and_head_are_required(self):
        for key, value in [('headRepositoryID', 124), ('baseRepositoryID', 124), ('headRepositoryID', True),
                           ('baseRepositoryID', True), ('headSHA', '4' * 40), ('baseSHA', ''),
                           ('number', 0), ('number', True)]:
            record = self.record()
            record['pullRequest'][key] = value
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                self.verify(self.built, [self.base, self.source], self.metadata(), record, self.digest)
        for record in (dict(self.record(), pullRequest=None), dict(self.record(), extra='untrusted')):
            with self.assertRaises(ValueError):
                self.verify(self.built, [self.base, self.source], self.metadata(), record, self.digest)

    def test_non_pr_event_cannot_claim_a_merge_or_pr_record(self):
        for record in (self.record('push'), dict(self.record('push', self.source, []), pullRequest={})):
            with self.assertRaises(ValueError):
                self.verify(record['builtRevision'], record['parents'], self.metadata('push'), record, self.digest)


QUALIFICATION = runpy.run_path(str(ROOT / 'scripts/linux-flatpak-qualification.py'))


class QualificationPreconditionsTests(unittest.TestCase):
    def source(self):
        return {'id': 7, 'run_attempt': 2, 'head_sha': '1' * 40,
                'head_repository': {'full_name': 'owner/repo', 'id': 123},
                'repository': {'id': 123, 'full_name': 'owner/repo'}, 'path': '.github/workflows/linux-flatpak.yml',
                'status': 'completed', 'conclusion': 'success', 'event': 'push', 'pull_requests': []}

    def test_successful_source_run(self):
        metadata = QUALIFICATION['source_metadata'](self.source(), '1' * 40, 'owner/repo', '7', '2' * 40)
        self.assertEqual(metadata['sourceSHA'], '1' * 40)

    def test_failed_cancelled_or_incomplete_source_is_refused(self):
        for status, conclusion in [('completed', 'failure'), ('completed', 'cancelled'),
                                  ('in_progress', None), ('completed', 'skipped')]:
            run = dict(self.source(), status=status, conclusion=conclusion)
            with self.subTest(status=status, conclusion=conclusion), self.assertRaises(ValueError):
                QUALIFICATION['source_metadata'](run, '1' * 40, 'owner/repo', '7', '2' * 40)

    def test_wrong_run_identity_is_refused(self):
        for change in [{'head_sha': '3' * 40}, {'head_repository': {'full_name': 'other/repo'}},
                       {'path': '.github/workflows/other.yml'}, {'id': 8}, {'run_attempt': 0},
                       {'run_attempt': True}, {'event': 'pull_request_target'},
                       {'head_repository': {'full_name': 'owner/repo', 'id': 124}},
                       {'repository': {'full_name': 'other/repo', 'id': 123}}]:
            with self.subTest(change=change), self.assertRaises(ValueError):
                QUALIFICATION['source_metadata'](dict(self.source(), **change), '1' * 40, 'owner/repo', '7', '2' * 40)

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


class BuildRecordLifecycleTests(unittest.TestCase):
    source = BuildRevisionTests.source
    base = BuildRevisionTests.base
    built = BuildRevisionTests.built
    digest = BuildRevisionTests.digest
    metadata = BuildRevisionTests.metadata
    record = BuildRevisionTests.record
    verify = staticmethod(BuildRevisionTests.verify)

    def environment(self):
        return {'GITHUB_REPOSITORY': 'owner/repo', 'GITHUB_REPOSITORY_ID': '123',
                'GITHUB_RUN_ID': '7', 'GITHUB_RUN_ATTEMPT': '2', 'GITHUB_SHA': self.built,
                'GITHUB_EVENT_NAME': 'pull_request',
                'GITHUB_WORKFLOW_REF': 'owner/repo/.github/workflows/linux-flatpak.yml@refs/pull/9/merge'}

    def event(self):
        return {'number': 9, 'repository': {'id': 123, 'full_name': 'owner/repo'}, 'pull_request': {
            'head': {'sha': self.source, 'repo': {'id': 123}},
            'base': {'sha': self.base, 'repo': {'id': 123}}}}

    def test_producer_distinguishes_trigger_source_from_actual_pr_merge_checkout(self):
        record = QUALIFICATION['build_record'](self.environment(), self.event(), self.built,
                                                [self.base, self.source], self.digest)
        self.assertEqual(record, self.record())
        self.assertNotEqual(record['sourceSHA'], record['builtRevision'])

    def test_association_removal_or_later_head_and_base_changes_do_not_rewrite_artifact_proof(self):
        for associations in ([], [{'head': {'sha': '9' * 40}, 'base': {'sha': '8' * 40}}]):
            run = QualificationPreconditionsTests().source()
            run.update(event='pull_request', pull_requests=associations)
            metadata = QUALIFICATION['source_metadata'](run, self.source, 'owner/repo', '7', 'a' * 40)
            self.verify(self.built, [self.base, self.source], metadata, self.record(), self.digest)
        # An older attempt's record is not borrowed by a later successful rerun.
        with self.assertRaises(ValueError):
            self.verify(self.built, [self.base, self.source], dict(self.metadata(), runAttempt=3),
                        self.record(), self.digest)

    def test_producer_refuses_wrong_event_repository_fork_base_or_checkout(self):
        changes = [('repository', 'id', True), ('repository', 'id', 124),
                   ('repository', 'full_name', 'other/repo'), ('head', 'repo', {'id': 124}),
                   ('base', 'repo', {'id': 124}), ('base', 'sha', '8' * 40)]
        for location, key, value in changes:
            event = self.event()
            target = event['repository'] if location == 'repository' else event['pull_request'][location]
            target[key] = value
            with self.subTest(location=location, key=key), self.assertRaises(ValueError):
                QUALIFICATION['build_record'](self.environment(), event, self.built,
                                               [self.base, self.source], self.digest)
        for change in ({'GITHUB_WORKFLOW_REF': 'owner/repo/.github/workflows/other.yml@refs/heads/main'},
                       {'GITHUB_SHA': self.source}, {'GITHUB_RUN_ATTEMPT': '0'}, {'GITHUB_RUN_ID': '7x'}):
            with self.subTest(change=change), self.assertRaises(ValueError):
                QUALIFICATION['build_record'](dict(self.environment(), **change), self.event(), self.built,
                                               [self.base, self.source], self.digest)

    def test_producer_non_pr_events_bind_exact_checkout_and_have_no_pr_claim(self):
        for event in ('push', 'workflow_dispatch'):
            environment = dict(self.environment(), GITHUB_EVENT_NAME=event, GITHUB_SHA=self.source)
            payload = {'repository': self.event()['repository']}
            record = QUALIFICATION['build_record'](environment, payload, self.source, [self.base], self.digest)
            self.assertIsNone(record['pullRequest'])
            self.verify(self.source, [self.base], self.metadata(event), record, self.digest)

    def test_raw_git_parent_headers_survive_a_real_shallow_checkout(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            original, shallow = root / 'original', root / 'shallow'
            subprocess.run(['git', 'init', '-q', str(original)], check=True)
            git = ['git', '-C', str(original)]
            for key, value in [('user.email', 'fixture@example.invalid'), ('user.name', 'Fixture')]:
                subprocess.run([*git, 'config', key, value], check=True)
            (original / 'file').write_text('first')
            subprocess.run([*git, 'add', 'file'], check=True)
            subprocess.run([*git, '-c', 'core.hooksPath=/dev/null', '-c', 'commit.gpgsign=false', 'commit', '-qm', 'first'], check=True)
            parent = subprocess.check_output([*git, 'rev-parse', 'HEAD'], text=True).strip()
            (original / 'file').write_text('second')
            subprocess.run([*git, '-c', 'core.hooksPath=/dev/null', '-c', 'commit.gpgsign=false', 'commit', '-qam', 'second'], check=True)
            subprocess.run(['git', 'clone', '-q', '--depth=1', original.as_uri(), str(shallow)], check=True)
            command = ['git', '-C', str(shallow)]
            head = subprocess.check_output([*command, 'rev-parse', 'HEAD'], text=True).strip()
            self.assertEqual(subprocess.check_output([*command, 'show', '-s', '--format=%P', 'HEAD'], text=True).strip(), '')
            self.assertEqual(QUALIFICATION['checkout_parents'](command), [parent])
            self.assertEqual(QUALIFICATION['checkout_parents'](command, head), [parent])

    def test_non_commit_git_objects_cannot_supply_parent_evidence(self):
        for kind in ('blob', 'tree', 'tag'):
            with mock.patch('subprocess.check_output', return_value=kind) as command, self.assertRaises(ValueError):
                QUALIFICATION['checkout_parents'](['git'], self.built)
            self.assertEqual(command.call_count, 1)

    def test_actual_blob_with_parent_looking_bytes_is_not_commit_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            subprocess.run(['git', 'init', '--bare', '-q', directory], check=True)
            git = ['git', '-C', directory]
            content = 'parent ' + self.base + '\nparent ' + self.source + '\n\nnot a commit'
            blob = subprocess.check_output([*git, 'hash-object', '-w', '--stdin'], input=content, text=True).strip()
            self.assertEqual(subprocess.check_output([*git, 'cat-file', '-p', blob], text=True), content)
            with self.assertRaises(ValueError):
                QUALIFICATION['checkout_parents'](git, blob)

    def test_unique_authenticated_artifact_files_and_streamed_bundle_digest(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bundle = root / 'JustSpeakToIt-x86_64.flatpak'
            revision, record = root / 'source-revision.txt', root / 'build-provenance.json'
            bundle.write_bytes(b'fixture bundle only')
            revision.write_text(self.built)
            record.write_text(json.dumps(self.record()))
            self.assertEqual(QUALIFICATION['artifact_files'](root), (bundle, revision, record))
            self.assertEqual(QUALIFICATION['file_digest'](bundle), hashlib.sha256(bundle.read_bytes()).hexdigest())
            record.unlink()
            with self.assertRaises(ValueError):
                QUALIFICATION['artifact_files'](root)
            record.write_text('{}')
            nested = root / 'nested'
            nested.mkdir()
            (nested / record.name).write_text('{}')
            with self.assertRaises(ValueError):
                QUALIFICATION['artifact_files'](root)
            (nested / record.name).unlink()
            for path in (bundle, revision, record):
                data = path.read_bytes()
                path.unlink()
                outside = root / 'other'
                outside.write_bytes(data)
                path.symlink_to(outside)
                with self.subTest(path=path), self.assertRaises(ValueError):
                    QUALIFICATION['artifact_files'](root)
                path.unlink()
                path.write_bytes(data)
                outside.unlink()

    def test_duplicate_or_oversized_record_metadata_is_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'record.json'
            for contents in ('{"version":1,"version":1}', ' ' * 65537):
                path.write_text(contents)
                with self.assertRaises(ValueError):
                    QUALIFICATION['load_record'](path)

    def test_record_writer_uses_actual_git_trigger_payload_and_exclusive_output(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bundle, event, output = root / 'bundle', root / 'event.json', root / 'record.json'
            bundle.write_bytes(b'fixture bundle only')
            event.write_text(json.dumps(self.event()))
            environment = dict(self.environment(), GITHUB_EVENT_PATH=str(event), UNRELATED_SECRET='never-export')
            raw_commit = 'tree ' + '0' * 40 + '\nparent ' + self.base + '\nparent ' + self.source + '\n\nmessage'
            with mock.patch.dict(os.environ, environment, clear=True), \
                    mock.patch('subprocess.check_output', side_effect=[self.built, 'commit', raw_commit]):
                QUALIFICATION['write_build_record'](bundle, output)
            actual = QUALIFICATION['load_record'](output)
            self.assertEqual(actual['parents'], [self.base, self.source])
            self.assertEqual(actual['bundleSHA256'], hashlib.sha256(bundle.read_bytes()).hexdigest())
            self.assertNotIn('never-export', output.read_text())
            before = output.read_bytes()
            with mock.patch.dict(os.environ, environment, clear=True), \
                    mock.patch('subprocess.check_output', side_effect=[self.built, 'commit', raw_commit]), self.assertRaises(FileExistsError):
                QUALIFICATION['write_build_record'](bundle, output)
            self.assertEqual(output.read_bytes(), before)

    def test_workflow_keeps_authenticated_download_before_record_validation_and_package_diff(self):
        workflow = (ROOT / '.github/workflows/linux-flatpak.yml').read_text()
        download = workflow.index("name: Download that run's authenticated bundle artifact")
        consumer = workflow.index("helper['VERIFY']['verify_revision']")
        package_diff = workflow.index("'diff', '--exit-code', built_sha")
        self.assertLess(download, consumer)
        self.assertLess(consumer, package_diff)
        self.assertIn("name: justspeaktoit-flatpak-x86_64\n          run-id: ${{ inputs.qualification_run_id }}", workflow)
        self.assertIn("github-token: ${{ github.token }}", workflow)
        self.assertIn("metadata = verify(run, sha, repo, run_id", workflow)
        self.assertIn("parents = helper['checkout_parents'](git, built_sha)", workflow)
        self.assertIn("metadata, record, helper['file_digest'](bundle)", workflow)


FLATPAK = runpy.run_path(str(ROOT / 'packaging/linux/verify-flatpak-manifest.py'))


class RuntimeCleanupTests(unittest.TestCase):
    def setUp(self):
        self.policy = json.loads((ROOT / 'scripts/linux-local-runtime/dependencies.json').read_text())
        self.target = self.policy['architectures']['x86_64']

    def fixture(self, root):
        for name in self.target['requiredModules']:
            data = ('owned bytes ' + name).encode()
            (root / name).write_bytes(data)
            (root / (name + '.23.0')).write_bytes(data)
            (root / (name.split('.so.')[0] + '.so')).symlink_to(name + '.23.0')
        for index in range(self.target['minimumCpuVariants']):
            (root / ('libggml-cpu-test_%d.so' % index)).write_bytes(b'owned CPU module')
        (root / self.policy['vulkan']['module']).write_bytes(b'owned Vulkan module')
        (root / 'libparakeet.so.1.9.4').write_bytes(b'owned unused module')
        (root / 'libparakeet.so.1').symlink_to('libparakeet.so.1.9.4')
        (root / 'libparakeet.so').symlink_to('libparakeet.so.1')

    def inspect(self, path):
        return {'type': 'DYN', 'machine': self.target['elfMachine'], 'soname': path.name,
                'needed': ['libggml-base.so.0'] if path.name != 'libggml-base.so.0' else ['libc.so.6'],
                'searchPaths': ['$ORIGIN']}

    def verify(self, root, cleanup=False, inspect=None):
        with contextlib.redirect_stdout(io.StringIO()):
            FLATPAK['verify_runtime'](root, self.policy, cleanup, inspect or self.inspect)

    def test_actual_cleanup_preserves_canonical_bytes_all_backends_and_external_symlink_target(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / 'runtime'
            root.mkdir()
            self.fixture(root)
            outside = Path(directory) / 'owned-license'
            outside.write_bytes(b'preserve external target')
            (root / 'libparakeet.so').unlink()
            (root / 'libparakeet.so').symlink_to(outside)
            kept = {p.name: p.read_bytes() for p in root.iterdir()
                    if not p.is_symlink() and not p.name.endswith('.23.0') and 'parakeet' not in p.name}
            self.verify(root, cleanup=True)
            for name, data in kept.items():
                self.assertFalse((root / name).is_symlink())
                self.assertEqual((root / name).read_bytes(), data)
            self.assertEqual(outside.read_bytes(), b'preserve external target')
            self.assertFalse(any('parakeet' in p.name or p.name.endswith('.23.0') for p in root.iterdir()))
            # Existing manifest cleanup still owns only the three development links.
            for name in self.target['requiredModules']:
                (root / (name.split('.so.')[0] + '.so')).unlink()
            self.verify(root)
            self.assertEqual(set(p.name for p in root.iterdir()), set(kept))

    def test_needed_parakeet_fullversion_or_missing_edge_refuses_before_any_delete(self):
        for needed in ['libparakeet.so.1', 'libwhisper.so.1.23.0', 'libmissing.so.1']:
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                self.fixture(root)
                before = set(root.iterdir())
                def inspect(path):
                    elf = self.inspect(path)
                    elf['needed'] = [needed]
                    return elf
                with self.assertRaisesRegex(ValueError, 'NEEDED'):
                    self.verify(root, True, inspect)
                self.assertEqual(set(root.iterdir()), before)

    def test_nonidentical_fullversion_original_refuses_without_removing_anything(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.fixture(root)
            (root / 'libwhisper.so.1.23.0').write_bytes(b'different bytes')
            before = set(root.iterdir())
            with self.assertRaisesRegex(ValueError, 'differs'):
                self.verify(root, True)
            self.assertEqual(set(root.iterdir()), before)

    def test_missing_canonical_cpu_or_vulkan_module_refuses(self):
        for name in ['libwhisper.so.1', 'libggml-cpu-test_0.so', self.policy['vulkan']['module']]:
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                self.fixture(root)
                (root / name).unlink()
                with self.assertRaisesRegex(ValueError, 'missing'):
                    self.verify(root, True)
                self.assertTrue((root / 'libparakeet.so.1.9.4').exists())

    def test_canonical_symlink_unknown_library_and_oversized_inventory_refuse(self):
        for variant in ['symlink', 'unknown', 'inventory']:
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                self.fixture(root)
                if variant == 'symlink':
                    (root / 'libwhisper.so.1').unlink()
                    (root / 'libwhisper.so.1').symlink_to('libwhisper.so.1.23.0')
                elif variant == 'unknown':
                    (root / 'libunexpected.so.1').write_bytes(b'unknown')
                else:
                    for index in range(65):
                        (root / ('extra-%d' % index)).touch()
                with self.assertRaises(ValueError):
                    self.verify(root, True)
                self.assertTrue((root / 'libparakeet.so.1.9.4').exists())

    def test_wrong_machine_type_soname_or_search_path_refuses(self):
        for change in [{'machine': 'wrong'}, {'type': 'EXEC'}, {'soname': 'libother.so.1'},
                       {'searchPaths': ['/usr/local/lib']}]:
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                self.fixture(root)
                with self.assertRaises(ValueError):
                    self.verify(root, True, lambda path: dict(self.inspect(path), **change))
                self.assertTrue((root / 'libparakeet.so.1.9.4').exists())

    def test_installed_check_refuses_leftovers_and_never_performs_cleanup(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.fixture(root)
            before = set(root.iterdir())
            with self.assertRaisesRegex(ValueError, 'remain installed'):
                self.verify(root)
            self.assertEqual(set(root.iterdir()), before)

    def test_readelf_adapter_parses_needed_soname_and_origin_with_bounded_host_tool(self):
        text = ('  Type: DYN (Shared object file)\n  Machine: Advanced Micro Devices X86-64\n'
                ' 0 (SONAME) Library soname: [libwhisper.so.1]\n'
                ' 0 (NEEDED) Shared library: [libggml.so.0]\n'
                ' 0 (RUNPATH) Library runpath: [$ORIGIN]\n')
        def execute(argv, **options):
            self.assertEqual(argv[:4], ['readelf', '--wide', '--file-header', '--dynamic'])
            self.assertLessEqual(options['timeout'], 10)
            self.assertTrue(callable(options['preexec_fn']))
            options['stdout'].write(text.encode())
        with mock.patch('subprocess.run', side_effect=execute):
            elf = FLATPAK['inspect_runtime_elf'](Path('owned-library'), FLATPAK['time'].monotonic() + 60)
        self.assertEqual(elf, {'type': 'DYN', 'machine': self.target['elfMachine'],
                             'soname': 'libwhisper.so.1', 'needed': ['libggml.so.0'], 'searchPaths': ['$ORIGIN']})

    def test_manifest_contract_accepts_only_checkout_local_verifier_and_policy(self):
        pin = json.loads((ROOT / 'scripts/windows-local-runtime/dependencies.json').read_text())['whisperCpp']
        manifest = {'finish-args': [
            '--share=network', '--share=ipc', '--socket=wayland', '--socket=fallback-x11',
            '--socket=pulseaudio', '--device=dri', '--talk-name=org.kde.StatusNotifierWatcher',
            '--env=JSTI_WHISPER_RUNTIME_DIRECTORY=/app/lib/justspeaktoit', '--env=GGML_NO_BACKTRACE=1'],
            'modules': [{'name': 'whisper-cpp', 'sources': [dict(type='git', **pin),
                {'type': 'file', 'path': 'verify-flatpak-manifest.py', 'dest-filename': 'jsti-flatpak-runtime.py'},
                {'type': 'file', 'path': '../../scripts/linux-local-runtime/dependencies.json',
                 'dest-filename': 'jsti-linux-runtime-policy.json'}],
                'config-opts': ['-DCMAKE_INSTALL_LIBDIR=lib/justspeaktoit', '-DGGML_NATIVE=OFF',
                                '-DGGML_CPU_ALL_VARIANTS=ON', '-DGGML_VULKAN=ON'],
                'post-install': ['cp -L /app/lib/justspeaktoit/$name',
                    'python3 "$FLATPAK_BUILDER_BUILDDIR/jsti-flatpak-runtime.py" '
                    '--runtime-directory /app/lib/justspeaktoit '
                    '--runtime-policy "$FLATPAK_BUILDER_BUILDDIR/jsti-linux-runtime-policy.json" --cleanup-runtime'],
                'cleanup': []}]}
        with contextlib.redirect_stdout(io.StringIO()):
            FLATPAK['verify'](manifest)
            absolute = copy.deepcopy(manifest)
            for source in absolute['modules'][0]['sources'][1:]:
                source['path'] = str((ROOT / 'packaging/linux' / source['path']).resolve())
            FLATPAK['verify'](absolute)
        for mutation in ['foreign-policy', 'missing-policy', 'vulkan-off', 'guard-before-copy']:
            candidate = copy.deepcopy(manifest)
            module = candidate['modules'][0]
            if mutation == 'foreign-policy':
                module['sources'][2]['path'] = '/tmp/unowned-policy.json'
            elif mutation == 'missing-policy':
                module['sources'].pop()
            elif mutation == 'vulkan-off':
                module['config-opts'].remove('-DGGML_VULKAN=ON')
            else:
                module['post-install'].reverse()
            with self.subTest(mutation=mutation), self.assertRaises(AssertionError):
                FLATPAK['verify'](candidate)

    def test_pinned_manifest_runs_guard_after_copy_before_strip_with_local_offline_policy(self):
        text = (ROOT / 'packaging/linux/com.justspeaktoit.JustSpeakToIt.yml').read_text()
        self.assertLess(text.index('cp -L /app/lib/justspeaktoit/$name'), text.index('python3 "$FLATPAK_BUILDER_BUILDDIR/jsti'))
        self.assertLess(text.index('python3 "$FLATPAK_BUILDER_BUILDDIR/jsti'), text.index('    cleanup:', text.index('- name: whisper-cpp')))
        for value in ['path: verify-flatpak-manifest.py', 'path: ../../scripts/linux-local-runtime/dependencies.json',
                      '-DGGML_CPU_ALL_VARIANTS=ON', '-DGGML_VULKAN=ON', 'whisper.cpp/LICENSE']:
            self.assertIn(value, text)
        self.assertNotIn('- /lib/justspeaktoit/libparakeet.so', text)
        checks = (ROOT / 'scripts/linux-flatpak-checks.sh').read_text()
        self.assertIn('flatpak info --user --show-location "$app"', checks)
        self.assertIn('--runtime-directory "$installed_root/files/lib/justspeaktoit"', checks)


if __name__ == '__main__':
    unittest.main()
