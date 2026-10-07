"""Compile actual Core lifecycle and both managers' account methods, no app graph.

Only UI/StoreKit containers and transport/storage boundaries are stand-ins.
The asynchronous production method bodies, session model and persistence protocol
are compiled verbatim, with their access modifiers widened in the disposable test.
"""
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from test_paid_access_recovery import block

ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('xcrun'), 'Apple Swift required')
class PaidSessionBoundaryTests(unittest.TestCase):
    def test_both_managers_preserve_logout_and_replacement_sessions(self):
        model = (ROOT / 'Sources/SpeakCore/PaidAccess/PaidAccessClient.swift').read_text()
        lifecycle = (ROOT / 'Sources/SpeakCore/PaidAccess/PaidAccessSessionLifecycle.swift').read_text()
        fixture = (ROOT / 'scripts/tests/fixtures/paid-session-races.swift').read_text()
        with tempfile.TemporaryDirectory(prefix='paid-session-boundary-') as temp:
            for path, purchase in [
                ('Sources/SpeakApp/PaidAccess/PaidAccessManager.swift', None),
                ('Sources/SpeakiOS/Services/PaidAccessStore.swift',
                 'Sources/SpeakiOS/Services/PaidAccessStore+Purchase.swift'),
            ]:
                with self.subTest(platform=path):
                    source = (ROOT / path).read_text()
                    methods = [block(source, 'func ' + name) for name in
                               ['currentSession()', 'clearSession()', 'refreshEntitlement()', 'signOut()']]
                    methods.append(block((ROOT / purchase).read_text() if purchase else source,
                                         'func syncIfSubscription('))
                    manager = '''@MainActor final class Manager {
                        let client: any PaidAccessClienting
                        let sessions: PaidAccessSessionLifecycle
                        var busyOperation = UUID()
                        var isSignedIn = true, isBusy = false
                        var entitlement = PaidEntitlement.unentitled
                        var policy = PaidRoutingPolicy.unknown
                        var lastError: String?
                        init(client: any PaidAccessClienting, store: any PaidAccessSessionStoring) {
                            self.client = client
                            self.sessions = PaidAccessSessionLifecycle(client: client, store: store)
                        }
                    ''' + '\n'.join(methods) + '\n}'
                    actual = (block(model, 'public struct PaidAccessSession:') + '\n'
                              + block(model, 'public protocol PaidAccessSessionStoring:') + '\n' + lifecycle)
                    swift = Path(temp) / 'Boundary.swift'
                    swift.write_text(fixture.replace('// MANAGER inserted here.', actual + '\n' + manager))
                    binary = Path(temp) / 'boundary'
                    result = subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library',
                                             '-module-cache-path', str(Path(temp) / 'cache'),
                                             str(swift), '-o', str(binary)], capture_output=True, text=True, timeout=60)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn('13 controlled account lifecycle cases passed', result.stdout)


if __name__ == '__main__':
    unittest.main()
