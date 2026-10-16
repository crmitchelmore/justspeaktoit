import contextlib
import errno
import gzip
import hashlib
import importlib.util
import io
from pathlib import Path
import stat
from types import SimpleNamespace
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location(
    'sample_contract', Path(__file__).resolve().parents[1] / 'collect-macos-sample-contract.py')
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class InstalledSampleContractTests(unittest.TestCase):
    def setUp(self):
        # Synthetic Darwin flags for mocked os.open, not host filesystem evidence.
        for name, value in (('O_NOFOLLOW', 0x100), ('O_DIRECTORY', 0x100000), ('O_NONBLOCK', 0x4)):
            if not hasattr(MODULE.os, name):
                flag = patch.object(MODULE.os, name, value, create=True)
                flag.start()
                self.addCleanup(flag.stop)

    def info(self, size, mode=stat.S_IFREG):
        return SimpleNamespace(st_dev=1, st_ino=2, st_size=size, st_mtime_ns=3,
                               st_ctime_ns=4, st_mode=mode)

    def read(self, data, info=None, limit=100):
        info = self.info(len(data)) if info is None else info
        with patch.object(MODULE, 'directory_fd', return_value=contextlib.nullcontext(10)), \
                patch.object(MODULE.os, 'open', return_value=11) as opened, \
                patch.object(MODULE.os, 'fstat', return_value=info), \
                patch.object(MODULE.os, 'stat', return_value=info):
            # BytesIO has no native descriptor; only the descriptor identity is mocked.
            stream = io.BytesIO(data)
            with patch.object(MODULE.os, 'fdopen', return_value=stream), \
                    patch.object(stream, 'fileno', return_value=11):
                result = MODULE.read_fixed(MODULE.MANUAL_PATHS[0], limit)
            self.assertTrue(opened.call_args.args[1] & MODULE.os.O_NOFOLLOW)
            self.assertTrue(opened.call_args.args[1] & MODULE.os.O_NONBLOCK)
            return result

    def testExactBytesAndDigest(self):
        data = b'.TH SAMPLE 1\r\nbinary:\xff\n'
        copied, metadata = self.read(data)
        self.assertEqual(copied, data)
        self.assertEqual(metadata, {'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()})

    def testOversizedRejected(self):
        with self.assertRaisesRegex(MODULE.RejectedEvidence, 'oversized'):
            self.read(b'x', self.info(101))

    def testNonRegularRejected(self):
        with self.assertRaisesRegex(MODULE.RejectedEvidence, 'not_regular'):
            self.read(b'x', self.info(1, stat.S_IFIFO))

    def testOutsideFixedAllowlistRejectedBeforeOpen(self):
        with patch.object(MODULE.os, 'open') as opened:
            with self.assertRaisesRegex(MODULE.RejectedEvidence, 'path_not_allowlisted'):
                MODULE.read_fixed('/tmp/sample.1', 100)
            opened.assert_not_called()

    def testUnsafeDirectoryRejected(self):
        with self.assertRaisesRegex(MODULE.RejectedEvidence, 'unsafe_directory'):
            with MODULE.directory_fd('/usr/../tmp'):
                self.fail('unsafe directory admitted')

    def testDirectoryComponentsNeverFollowSymlinks(self):
        with patch.object(MODULE.os, 'open', side_effect=[10, OSError(errno.ELOOP, 'loop')]) as opened, \
                patch.object(MODULE.os, 'close') as closed:
            with self.assertRaises(OSError):
                with MODULE.directory_fd('/usr/share'):
                    self.fail('symlink admitted')
            self.assertTrue(opened.call_args.args[1] & MODULE.os.O_NOFOLLOW)
            closed.assert_called_once_with(10)

    def testGzipBoundsAndPreservesCompressedBytes(self):
        data = gzip.compress(b'.TH SAMPLE 1\n', mtime=0)
        MODULE.check_gzip(data)
        copied, _ = self.read(data)
        self.assertEqual(copied, data)
        with patch.object(MODULE, 'MAX_EXPANDED_BYTES', 8):
            with self.assertRaisesRegex(MODULE.RejectedEvidence, 'gzip_expansion_limit'):
                MODULE.check_gzip(data)

    def testGzipInvalidTruncatedAndTrailingRejected(self):
        for data in (b'not gzip', gzip.compress(b'manual')[:-2],
                     gzip.compress(b'manual') + b'trailing', gzip.compress(b''),
                     gzip.compress(b'manual') + gzip.compress(b'second member')):
            with self.subTest(data=data):
                with self.assertRaises(MODULE.RejectedEvidence):
                    MODULE.check_gzip(data)

    def collect(self, reader):
        writes = {}
        with patch.object(MODULE, 'MANUAL_PATHS', ('/usr/share/man/man1/sample.1',)), \
                patch.object(MODULE, 'read_fixed', side_effect=reader), \
                patch.object(MODULE, 'write_at', side_effect=lambda fd, name, data: writes.update({name: data})), \
                contextlib.redirect_stderr(io.StringIO()) as stderr:
            inventory = MODULE.collect(12)
        return inventory, writes, stderr.getvalue()

    def testAbsentManualHasExplicitUnavailableReceipt(self):
        inventory, writes, stderr = self.collect(
            lambda *args, **kwargs: (_ for _ in ()).throw(FileNotFoundError(errno.ENOENT, 'missing')))
        self.assertEqual(inventory['status'], 'unavailable')
        self.assertEqual(inventory['manuals'][0]['reason'], f'io_errno_{errno.ENOENT}')
        self.assertFalse(inventory['contract_established'])
        self.assertFalse(inventory['sampling_performed'])
        self.assertEqual(writes, {})
        self.assertIn('contract NOT established', stderr)

    def testReadFailureHasExplicitUnavailableReason(self):
        inventory, _, stderr = self.collect(
            lambda *args, **kwargs: (_ for _ in ()).throw(PermissionError(errno.EACCES, 'private')))
        self.assertEqual(inventory['manuals'][0]['reason'], f'io_errno_{errno.EACCES}')
        self.assertIn('unavailable', stderr)
        self.assertNotIn('private', stderr)

    def testCollectionPreservesRawManualAndHashesToolWithoutRetainingIt(self):
        data = b'.TH SAMPLE 1\r\n'
        calls = []

        def reader(path, limit, retain=True):
            calls.append((path, limit, retain))
            return (data if retain else b''), {'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()}

        inventory, writes, _ = self.collect(reader)
        self.assertEqual(writes, {'manual-00-sample.1': data})
        self.assertEqual(inventory['status'], 'evidence_collected_for_review')
        self.assertFalse(inventory['contract_established'])
        self.assertEqual(calls[-1], (MODULE.TOOL_PATH, MODULE.MAX_TOOL_BYTES, False))

    def testGzipCollectionPublishesOriginalCompressedBytes(self):
        data = gzip.compress(b'.TH SAMPLE 1\n', mtime=0)
        with patch.object(MODULE, 'MANUAL_PATHS', ('/usr/share/man/man1/sample.1.gz',)), \
                patch.object(MODULE, 'read_fixed', return_value=(data, {'bytes': len(data)})), \
                patch.object(MODULE, 'write_at') as written:
            inventory = MODULE.collect(12)
        written.assert_called_once_with(12, 'manual-00-sample.1.gz', data)
        self.assertEqual(inventory['manuals'][0]['status'], 'collected')

    def testUnavailableMainWritesReceiptAndExitsThree(self):
        inventory = {'status': 'unavailable', 'contract_established': False}
        environment = {'GITHUB_ACTIONS': 'true', 'GITHUB_RUN_ID': '12',
                       'GITHUB_RUN_ATTEMPT': '1', 'GITHUB_SHA': 'a' * 40,
                       'RUNNER_TEMP': '/runner/temp'}
        with patch.object(MODULE.sys, 'platform', 'darwin'), \
                patch.dict(MODULE.os.environ, environment, clear=True), \
                patch.object(MODULE, 'directory_fd', return_value=contextlib.nullcontext(10)), \
                patch.object(MODULE.os, 'mkdir'), \
                patch.object(MODULE.os, 'open', return_value=11), \
                patch.object(MODULE.os, 'close') as closed, \
                patch.object(MODULE, 'collect', return_value=inventory), \
                patch.object(MODULE, 'write_at') as written:
            self.assertEqual(MODULE.main(), 3)
        self.assertEqual(written.call_args.args[:2], (11, 'inventory.json'))
        self.assertIn(b'"status": "unavailable"', written.call_args.args[2])
        closed.assert_called_once_with(11)

    def testLocalEntryDoesNotReadAnyEvidence(self):
        with patch.object(MODULE.sys, 'platform', 'darwin'), \
                patch.dict(MODULE.os.environ, {}, clear=True), \
                patch.object(MODULE, 'collect') as collected, \
                contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(MODULE.main(), 1)
        collected.assert_not_called()


if __name__ == '__main__':
    unittest.main()
