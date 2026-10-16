#!/usr/bin/env python3
"""Pure synthetic report fixtures: no Apple tools, tests or crash injection."""

import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[1] / 'collect-macos-xctest-crashes.py'
SPEC = importlib.util.spec_from_file_location('macos_xctest_crashes', SCRIPT)
collector = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(collector)


class MacOSXCTestCrashReportsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.workspace = self.root / 'workspace with spaces'
        self.workspace.mkdir()
        self.reports = self.root / 'DiagnosticReports'
        self.reports.mkdir()
        self.output = self.root / 'output'
        # Mtime and birthtime are controlled independently, without clock deadlines.
        birth = mock.patch.object(collector, 'birth_ns', return_value=0)
        birth.start()
        self.addCleanup(birth.stop)
        self.boundary = 1_000_000_000_000_000
        self.now = self.boundary + 10_000_000
        self.context = {
            'schema': 1, 'workspace': self.workspace.as_posix(), 'boundary_ns': self.boundary,
            'GITHUB_SHA': '5e7a8c5d6e23f95ba2505edaf6ac47e47a1b1cf0',
            'GITHUB_REPOSITORY': 'fixture/repository', 'GITHUB_RUN_ID': '123',
            'GITHUB_RUN_ATTEMPT': '1', 'GITHUB_JOB': 'build-macos',
        }

    def bundle(self, workspace=None, configuration='debug', name='SpeakAppPackageTests'):
        return ((workspace or self.workspace).as_posix()
                + '/.build/x86_64-apple-macosx/' + configuration
                + '/' + name + '.xctest/Contents/MacOS/' + name)

    def ips(self, path=None):
        header = json.dumps({'app_name': 'xctest'})
        payload = json.dumps({
            'procName': 'xctest', 'usedImages': [{'path': path or self.bundle()}],
            'threads': [{'frames': [{'symbol': 'synthetic_runtime_symbol'}]}],
        })
        return (header + '\n' + payload + '\n').encode()

    def report(self, name='xctest-2026-10-20.ips', data=None, stamp=None):
        path = self.reports / name
        path.write_bytes(self.ips() if data is None else data)
        value = self.boundary + 1 if stamp is None else stamp
        os.utime(path, ns=(value, value))
        return path

    def collect(self, roots=None, **kwargs):
        result = collector.collect_reports(
            self.context, [('user', self.reports)] if roots is None else roots,
            self.output, now_ns=self.now, **kwargs)
        self.assertEqual(json.loads((self.output / 'inventory.json').read_bytes()), result)
        self.assertEqual(result['test_outcome'], 'not_evaluated_by_collector')
        self.assertEqual(result['context'], self.context)
        self.assertLessEqual(result['read_bytes_reserved'], collector.MAX_READ_BYTES)
        self.assertLessEqual(result['copied_bytes'], collector.MAX_TOTAL_BYTES)
        return result

    def reasons(self, result):
        return [item['reason'] for item in result['rejected']]

    def test_xctest_ips_filename_exact_workspace_bundle_and_raw_bytes(self):
        raw = self.ips().replace(b'/', b'\\/')
        self.report(data=raw)
        result = self.collect()
        self.assertEqual(result['status'], 'reports_collected')
        self.assertEqual(len(result['reports']), 1)
        report = result['reports'][0]
        self.assertEqual((self.output / report['file']).read_bytes(), raw)
        self.assertEqual(report['sha256'], hashlib.sha256(raw).hexdigest())
        self.assertEqual(report['bytes'], len(raw))
        self.assertIn(b'synthetic_runtime_symbol', raw)

    def test_plain_crash_binary_images_preserve_crlf_and_no_final_newline(self):
        raw = ('Process: xctest [123]\r\nPath: /Applications/Xcode.app/xctest\r\n'
               'Binary Images:\r\n0x100 - 0x200 +SpeakAppPackageTests <ABC> '
               + self.bundle()).encode()
        self.report(name='xctest_2026-10-20.crash', data=raw)
        result = self.collect()
        self.assertEqual(result['status'], 'reports_collected')
        self.assertEqual((self.output / result['reports'][0]['file']).read_bytes(), raw)

    def test_wrong_workspace_prefix_bundle_and_release_are_out_of_scope(self):
        paths = [
            self.bundle(workspace=self.root / 'workspace with spaces-other'),
            self.bundle(name='OtherPackageTests'),
            self.bundle(configuration='release'),
            self.bundle() + '-other',
            self.bundle().replace('/x86_64-apple-macosx/', '/../'),
        ]
        for index, path in enumerate(paths):
            self.report(name=f'xctest-wrong-{index}.ips', data=self.ips(path))
        result = self.collect()
        self.assertEqual(self.reasons(result), ['bundle_mismatch'] * len(paths))
        self.assertEqual(result['reports'], [])
        self.assertEqual(result['status'], 'evidence_gap')

    def test_stale_and_future_reports_are_explicitly_rejected(self):
        self.report(name='xctest-stale.ips', stamp=self.boundary - 1)
        self.report(name='xctest-future.ips', stamp=self.now + 1)
        result = self.collect()
        self.assertCountEqual(self.reasons(result), ['stale', 'future_timestamp'])
        self.assertEqual(result['reports'], [])

    def test_creation_after_boundary_qualifies_without_recent_mtime(self):
        self.report(stamp=self.boundary - 1)
        with mock.patch.object(collector, 'birth_ns', return_value=self.boundary + 1):
            result = self.collect()
        self.assertEqual(result['status'], 'reports_collected')
        self.assertEqual(result['reports'][0]['birthtime_ns'], self.boundary + 1)

    def test_symlink_report_and_nonregular_candidate_are_never_read(self):
        target = self.root / 'outside.ips'
        target.write_bytes(self.ips())
        (self.reports / 'xctest-linked.ips').symlink_to(target)
        (self.reports / 'xctest-directory.ips').mkdir()
        result = self.collect()
        self.assertCountEqual(self.reasons(result), ['symlink', 'not_regular'])
        self.assertEqual(result['read_bytes_reserved'], 0)
        self.assertEqual(result['reports'], [])

    def test_symlink_directory_is_not_followed(self):
        self.report()
        alias = self.root / 'aliased-reports'
        alias.symlink_to(self.reports, target_is_directory=True)
        result = self.collect(roots=[('user', alias)])
        self.assertEqual(result['directories'][0]['status'], 'symlink_or_not_directory')
        self.assertEqual(result['entries_examined'], 0)
        self.assertEqual(result['reports'], [])

    def test_replacement_between_stat_and_open_is_rejected_before_read(self):
        path = self.report()
        replacement = self.root / 'replacement'
        replacement.write_bytes(self.ips())
        original_open = os.open

        def replace_then_open(name, flags, *args, **kwargs):
            if name == path.name:
                os.replace(replacement, path)
            return original_open(name, flags, *args, **kwargs)

        with mock.patch.object(collector.os, 'open', side_effect=replace_then_open):
            result = self.collect()
        self.assertEqual(self.reasons(result), ['changed_before_read'])
        self.assertEqual(result['read_bytes_reserved'], 0)
        self.assertEqual(result['reports'], [])

    def test_mutation_during_read_cannot_publish_partial_or_changed_evidence(self):
        path = self.report()
        original_stat = os.fstat
        calls = 0

        def mutate_then_stat(fd):
            nonlocal calls
            calls += 1
            if calls == 2:
                os.utime(path, ns=(self.boundary + 2, self.boundary + 2))
            return original_stat(fd)

        with mock.patch.object(collector.os, 'fstat', side_effect=mutate_then_stat):
            result = self.collect()
        self.assertEqual(self.reasons(result), ['changed_during_read'])
        self.assertGreater(result['read_bytes_reserved'], 0)
        self.assertEqual(result['reports'], [])

    def test_oversize_report_is_rejected_before_any_content_read(self):
        path = self.report()
        with path.open('wb') as stream:
            stream.truncate(collector.MAX_REPORT_BYTES + 1)
        result = self.collect()
        self.assertEqual(self.reasons(result), ['oversize'])
        self.assertEqual(result['read_bytes_reserved'], 0)
        self.assertEqual(result['reports'], [])

    def test_missing_directory_and_empty_directory_emit_inventory_not_a_fake_report(self):
        result = self.collect(roots=[('user', self.root / 'missing'), ('system', self.reports)])
        self.assertEqual(result['directories'], [
            {'root': 'user', 'status': 'missing'}, {'root': 'system', 'status': 'available'},
        ])
        self.assertIn('user:missing', result['evidence_gaps'])
        self.assertIn('no_matching_reports', result['evidence_gaps'])
        self.assertEqual(result['reports'], [])
        self.assertEqual([path.name for path in self.output.iterdir()], ['inventory.json'])

    def test_unrelated_names_are_not_read_even_with_matching_bundle(self):
        self.report(name='OtherProcess-2026.ips')
        self.report(name='xctest-looking.ips.other')
        result = self.collect()
        self.assertEqual(result['candidates_examined'], 0)
        self.assertEqual(result['read_bytes_reserved'], 0)
        self.assertEqual(result['reports'], [])

    def test_report_count_and_read_budget_limits_are_explicit(self):
        self.report(name='xctest-one.ips')
        self.report(name='xctest-two.ips')
        with mock.patch.object(collector, 'MAX_REPORTS', 1):
            result = self.collect()
        self.assertEqual(len(result['reports']), 1)
        self.assertEqual(self.reasons(result), ['report_limit'])
        self.assertEqual(result['status'], 'partial')
        with mock.patch.object(collector, 'MAX_READ_BYTES', 1):
            self.output = self.root / 'read-limited'
            result = self.collect()
            self.assertEqual(self.reasons(result), ['read_byte_limit', 'read_byte_limit'])
            self.assertEqual(result['read_bytes_reserved'], 0)
            self.assertEqual(result['reports'], [])

    def test_scan_candidate_and_copy_byte_limits_are_bounded(self):
        self.report(name='xctest-one.ips')
        self.report(name='xctest-two.ips')
        for constant, limit, gap in [
            ('MAX_ENTRIES', 1, 'user:entry_limit'),
            ('MAX_CANDIDATES', 1, 'user:candidate_limit'),
            ('MAX_TOTAL_BYTES', 1, 'report_or_byte_limit'),
        ]:
            with self.subTest(constant=constant), mock.patch.object(collector, constant, limit):
                self.output = self.root / constant
                result = self.collect()
                self.assertIn(gap, result['evidence_gaps'])
                self.assertEqual(result['status'], 'partial' if result['reports'] else 'evidence_gap')

    def test_malformed_report_cannot_supply_a_fake_bundle_match(self):
        self.report(data=b'{"usedImages": [{"path": "' + self.bundle().encode() + b'"}]} garbage')
        result = self.collect()
        self.assertEqual(self.reasons(result), ['malformed_report'])
        self.assertEqual(result['reports'], [])

    def test_unavailable_boundary_never_inspects_reports(self):
        self.report()
        result = self.collect(unavailable='boundary_step_not_successful')
        self.assertEqual(result['directories'], [])
        self.assertEqual(result['entries_examined'], 0)
        self.assertIn('boundary_step_not_successful', result['evidence_gaps'])
        self.assertEqual(result['reports'], [])

    def test_boundary_preserves_exact_run_identity_and_cannot_be_overwritten(self):
        expected = {key: value for key, value in self.context.items() if key != 'boundary_ns'}
        with collector.directory_fd(self.root) as fd:
            collector.write_at(fd, 'boundary.json', collector.json_bytes(self.context))
        self.assertEqual(collector.load_boundary(self.root, 'boundary.json', expected), self.context)
        with self.assertRaises(ValueError):
            collector.load_boundary(self.root, 'boundary.json', {**expected, 'GITHUB_SHA': '0' * 40})
        with collector.directory_fd(self.root) as fd, self.assertRaises(FileExistsError):
            collector.write_at(fd, 'boundary.json', b'not a boundary')
        self.assertEqual(json.loads((self.root / 'boundary.json').read_bytes()), self.context)

    def test_cli_missing_boundary_emits_gap_inventory_without_scanning(self):
        self.report()
        env = {key: value for key, value in self.context.items() if key.startswith('GITHUB_')}
        env.update(GITHUB_WORKSPACE=str(self.workspace), RUNNER_TEMP=str(self.root),
                   JSTI_XCTEST_BOUNDARY_OUTCOME='success')
        with mock.patch.dict(os.environ, env, clear=True), \
                mock.patch('sys.argv', [str(SCRIPT), 'collect']), \
                mock.patch('sys.stderr', new_callable=io.StringIO) as errors, \
                mock.patch.object(collector, 'directory_fd', wraps=collector.directory_fd) as opened:
            self.assertEqual(collector.main(), 3)
        self.assertNotIn('DiagnosticReports', str(opened.call_args_list))
        self.assertIn('evidence_gap', errors.getvalue())
        output = self.root / 'jsti-xctest-debug-123-1'
        inventory = json.loads((output / 'inventory.json').read_bytes())
        self.assertIn('boundary_unavailable:missing', inventory['evidence_gaps'])
        self.assertEqual(inventory['directories'], [])
        self.assertEqual(inventory['reports'], [])

    def test_cli_failed_boundary_cannot_reuse_old_context_or_upload_existing_output(self):
        env = {key: value for key, value in self.context.items() if key.startswith('GITHUB_')}
        env.update(GITHUB_WORKSPACE=str(self.workspace), RUNNER_TEMP=str(self.root),
                   JSTI_XCTEST_BOUNDARY_OUTCOME='failure')
        with mock.patch.dict(os.environ, env, clear=True), \
                mock.patch('sys.argv', [str(SCRIPT), 'collect']), \
                mock.patch('sys.stderr', new_callable=io.StringIO), \
                mock.patch.object(collector, 'load_boundary') as boundary:
            self.assertEqual(collector.main(), 3)
            boundary.assert_not_called()
            output = self.root / 'jsti-xctest-debug-123-1'
            original = (output / 'inventory.json').read_bytes()
            self.assertEqual(collector.main(), 1)
            self.assertEqual((output / 'inventory.json').read_bytes(), original)


if __name__ == '__main__':
    unittest.main()
