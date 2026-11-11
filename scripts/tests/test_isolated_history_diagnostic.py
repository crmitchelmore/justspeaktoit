"""Tests for scripts/ci/isolated-history-diagnostic.py, ci-macos-debug.yml's History fixture diagnostic."""
import importlib.util
import io
import json
import shutil
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[1] / 'ci' / 'isolated-history-diagnostic.py'
_spec = importlib.util.spec_from_file_location('isolated_history_diagnostic', SCRIPT)
diagnostic = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(diagnostic)

METHODS = ['testControlRecordWithoutSession_RoundTripsRawAndPolishedValues',
           'testControlResultAfterFinish_RoundTripsSuccessfulPolish',
           'testNativeAndPortableHistory_RoundTripRawAndSuccessfulPolishWithoutRerunningClient']


def case(method, state, form='-[SpeakDesktopTests.DesktopLivePolishHistoryTests {}]'):
    return f"Test Case '{form.format(method)}' {state} (0.001 seconds).\n"


PASSING = ''.join(case(m, 'started') + case(m, 'passed') for m in METHODS)


class DiagnosticTests(unittest.TestCase):
    def setUp(self):
        self.directory = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.directory)

    def capture(self, text):
        stdin = mock.Mock(buffer=io.BytesIO(text.encode()))
        with mock.patch.object(sys, 'stdin', stdin):
            return diagnostic.main(['capture', str(self.directory)])

    def summarise(self, command_status=0, capture_status=0):
        with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            status = diagnostic.main(['summarise', str(self.directory), str(command_status), str(capture_status)])
        return status, json.loads((self.directory / 'result.json').read_text(encoding='ascii'))

    def test_exact_cases_passing_is_an_isolated_pass(self):
        self.assertEqual(self.capture(PASSING), 0)
        status, result = self.summarise()
        self.assertEqual(status, 0)
        self.assertEqual(result['status'], 'isolated_pass')
        self.assertTrue(result['selection_verified'])
        self.assertFalse(result['parity_qualification'])
        self.assertEqual(result['observed_case_event_counts'], {'started': 3, 'passed': 3, 'failed': 0, 'skipped': 0})

    def test_every_case_name_form_is_accepted(self):
        forms = ['SpeakDesktopTests.DesktopLivePolishHistoryTests.{}', 'DesktopLivePolishHistoryTests.{}',
                 '-[SpeakDesktopTests.DesktopLivePolishHistoryTests {}]']
        self.capture(''.join(case(m, 'started', f) + case(m, 'passed', f) for m, f in zip(METHODS, forms)))
        self.assertEqual(self.summarise()[1]['status'], 'isolated_pass')

    def test_a_failing_case_is_an_isolated_failure(self):
        self.capture(PASSING.replace('passed', 'failed', 1))
        status, result = self.summarise(command_status=1)
        self.assertEqual((status, result['status']), (1, 'isolated_failure'))
        self.assertTrue(result['selection_verified'])

    def test_unknown_or_missing_cases_leave_selection_unverified(self):
        self.capture(PASSING + case('somethingElse', 'started'))
        status, result = self.summarise()
        self.assertEqual((status, result['status']), (1, 'selection_or_capture_unverified'))
        self.assertEqual(result['unknown_case_event_count'], 1)

    def test_truncated_capture_keeps_the_first_mebibyte_and_is_unverified(self):
        self.capture(PASSING + 'x' * (1024 * 1024))
        self.assertEqual((self.directory / 'output.log').stat().st_size, 1024 * 1024)
        status, result = self.summarise()
        self.assertTrue(result['capture']['truncated'])
        self.assertEqual((status, result['case_counts_complete']), (1, False))

    def test_missing_capture_is_reported_as_unavailable(self):
        status, result = self.summarise(capture_status=1)
        self.assertEqual(result['capture'], {'status': 'unavailable', 'truncated': True})
        self.assertEqual(status, 1)

    def test_usage_error(self):
        with redirect_stderr(io.StringIO()):
            self.assertEqual(diagnostic.main(['bogus']), 2)


if __name__ == '__main__':
    unittest.main()
