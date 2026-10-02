"""Run the real portable-boundary verifier with narrow manifest mutations.

Only a disposable source copy is edited. Native portable CI separately compiles
these actual domain/session files; this test does not claim runtime paid access.
"""
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DOMAIN = [
    'PaidAccess/PaidAccessModels.swift',
    'PaidAccess/PaidAccessRouting.swift',
    'PaidAccess/PaidAccessClient.swift',
    'PaidAccess/PaidAccessSessionLifecycle.swift',
]
ADAPTERS = [
    'PaidAccess/PaidAccessHTTPClient.swift',
    'PaidAccess/PaidAudioPayload.swift',
    'PaidAccess/PaidStoreKitSync.swift',
]


class PaidPortableBoundaryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='paid-portable-boundary-')
        cls.addClassCleanup(cls.temp.cleanup)
        cls.root = Path(cls.temp.name)
        (cls.root / 'scripts').mkdir()
        shutil.copy2(ROOT / 'scripts/verify-portable-core-boundary.py', cls.root / 'scripts')
        for target in ['SpeakCore', 'SpeakSync', 'SpeakDesktop', 'SpeakDesktopHost']:
            shutil.copytree(ROOT / 'Sources' / target, cls.root / 'Sources' / target)
        cls.manifest = (ROOT / 'Package.swift').read_text()

    def verify(self, manifest):
        (self.root / 'Package.swift').write_text(manifest)
        return subprocess.run([sys.executable, str(self.root / 'scripts/verify-portable-core-boundary.py')],
                              capture_output=True, text=True, timeout=15)

    def test_current_boundary_retains_domains_and_excludes_apple_io(self):
        result = self.verify(self.manifest)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('Portable boundary:', result.stdout)

    def test_excluding_each_shared_paid_contract_is_rejected(self):
        marker = 'let appleCoreSources: [String] = [\n'
        self.assertEqual(self.manifest.count(marker), 1)
        for path in DOMAIN:
            with self.subTest(path=path):
                result = self.verify(self.manifest.replace(marker, marker + f'    "{path}",\n'))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('Canonical domain sources excluded from portable builds: ' + path, result.stderr)

    def test_admitting_each_apple_paid_adapter_is_rejected(self):
        for path in ADAPTERS:
            with self.subTest(path=path):
                line = f'    "{path}",\n'
                self.assertEqual(self.manifest.count(line), 1)
                result = self.verify(self.manifest.replace(line, ''))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('Apple paid adapters admitted to portable builds: ' + path, result.stderr)


if __name__ == '__main__':
    unittest.main()
