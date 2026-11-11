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
    'PaidAccess/Apple/PaidAccessHTTPClient.swift',
    'PaidAccess/Apple/PaidAudioPayload.swift',
    'PaidAccess/Apple/PaidStoreKitSync.swift',
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

    def moved(self, path, destination):
        """Moves one copied source for the duration of a check."""
        source = self.root / 'Sources' / 'SpeakCore' / path
        target = self.root / 'Sources' / 'SpeakCore' / destination
        source.rename(target)
        self.addCleanup(target.rename, source)
        return Path(destination).as_posix()

    def test_moving_each_shared_paid_contract_into_the_apple_folder_is_rejected(self):
        for path in DOMAIN:
            with self.subTest(path=path):
                self.moved(path, 'PaidAccess/Apple/' + Path(path).name)
                result = self.verify(self.manifest)
                self.doCleanups()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('Canonical domain sources excluded from portable builds: ' + path, result.stderr)

    def test_moving_each_apple_paid_adapter_out_of_the_apple_folder_is_rejected(self):
        for path in ADAPTERS:
            with self.subTest(path=path):
                admitted = self.moved(path, 'PaidAccess/' + Path(path).name)
                result = self.verify(self.manifest)
                self.doCleanups()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('Apple paid adapters admitted to portable builds: ' + admitted, result.stderr)

    def test_entries_name_existing_unnested_folders_only(self):
        marker = 'let appleCoreSources: [String] = [\n'
        self.assertEqual(self.manifest.count(marker), 1)
        cases = {
            'NoSuchFolder': 'Invalid or stale Apple source exclusion: NoSuchFolder',
            'AppleUI/SkeletonLoadingViews.swift':
                'Apple source exclusion AppleUI/SkeletonLoadingViews.swift must name an Apple-only folder, not a file',
            'PaidAccess': 'Apple source exclusion PaidAccess/Apple is already covered by the PaidAccess folder',
        }
        for entry, message in cases.items():
            with self.subTest(entry=entry):
                result = self.verify(self.manifest.replace(marker, marker + f'    "{entry}",\n'))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)

    def test_sync_entries_are_checked_like_core_entries(self):
        marker = 'let appleSyncSources: [String] = [\n'
        self.assertEqual(self.manifest.count(marker), 1)
        result = self.verify(self.manifest.replace(marker, marker + '    "CloudKitWebKeySync.swift",\n'))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Apple source exclusion CloudKitWebKeySync.swift must name an Apple-only folder', result.stderr)

    def test_swiftui_view_outside_apple_ui_folder_is_rejected(self):
        stray = self.root / 'Sources' / 'SpeakCore' / 'App' / 'StrayView.swift'
        stray.write_text('import SwiftUI\n\npublic struct StrayView: View {\n    public var body: some View { EmptyView() }\n}\n')
        try:
            result = self.verify(self.manifest)
        finally:
            stray.unlink()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('SwiftUI view outside Sources/SpeakCore/AppleUI: App/StrayView.swift', result.stderr)


if __name__ == '__main__':
    unittest.main()
