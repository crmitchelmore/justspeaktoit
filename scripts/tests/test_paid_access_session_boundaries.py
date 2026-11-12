"""Compile the actual Core lifecycle, the shared PaidAccessFlow and both
platform owners' account entry points, with no app graph.

Only UI/StoreKit containers and transport/storage boundaries are stand-ins.
The asynchronous production method bodies, session model and persistence protocol
are compiled verbatim, with their access modifiers widened in the disposable test.
"""
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from test_paid_access_recovery import block

ROOT = Path(__file__).resolve().parents[2]
FLOW = 'Sources/SpeakCore/PaidAccess/Apple/PaidAccessFlow.swift'
# Purchase and sign-in need real StoreKit products and Apple identity; the
# session, entitlement and transaction-update paths these harnesses run do not.
UNUSED_FLOW_METHODS = ['public func signIn(', 'public func loadProducts(', 'public func product(for',
                       'public func purchaseThroughStoreKit(', 'public func restoreStoreKitPurchases(',
                       'private func handlePurchaseResult(']


def shared_flow():
    """The production PaidAccessFlow and its state, access modifiers widened."""
    source = (ROOT / FLOW).read_text()
    flow = block(source, 'public final class PaidAccessFlow')
    for marker in UNUSED_FLOW_METHODS:
        flow = flow.replace(block(flow, marker), '')
    swift = block(source, 'public struct PaidAccessFlowState') + '\n@MainActor\n' + flow
    return re.sub(r'\b(?:public|private\(set\)|private) ', '', swift)


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('xcrun'), 'Apple Swift required')
class PaidSessionBoundaryTests(unittest.TestCase):
    def test_both_managers_preserve_logout_and_replacement_sessions(self):
        model = (ROOT / 'Sources/SpeakCore/PaidAccess/PaidAccessClient.swift').read_text()
        lifecycle = (ROOT / 'Sources/SpeakCore/PaidAccess/PaidAccessSessionLifecycle.swift').read_text()
        fixture = (ROOT / 'scripts/tests/fixtures/paid-session-races.swift').read_text()
        actual = '\n'.join([block(model, 'public struct PaidAccessSession:'),
                            block(model, 'public protocol PaidAccessSessionStoring:'), lifecycle, shared_flow()])
        with tempfile.TemporaryDirectory(prefix='paid-session-boundary-') as temp:
            for path in ['Sources/SpeakApp/PaidAccess/PaidAccessManager.swift',
                         'Sources/SpeakiOS/Services/PaidAccessStore.swift']:
                with self.subTest(platform=path):
                    source = (ROOT / path).read_text()
                    # Each owner's real logout/entitlement entry points drive the
                    # shared flow; the rest only exposes flow state to the fixture.
                    entry_points = [block(source, 'func ' + name)
                                    for name in ['refreshEntitlement()', 'signOut()']]
                    manager = '''@MainActor final class Manager {
                        let flow: PaidAccessFlow
                        init(client: any PaidAccessClienting, store: any PaidAccessSessionStoring) {
                            self.flow = PaidAccessFlow(client: client, sessionStore: store)
                        }
                        var sessions: PaidAccessSessionLifecycle { flow.sessions }
                        var busyOperation: UUID { get { flow.busyOperation } set { flow.busyOperation = newValue } }
                        var isSignedIn: Bool { get { flow.state.isSignedIn } set { flow.state.isSignedIn = newValue } }
                        var isBusy: Bool { get { flow.state.isBusy } set { flow.state.isBusy = newValue } }
                        var entitlement: PaidEntitlement { flow.state.entitlement }
                        var policy: PaidRoutingPolicy { flow.state.policy }
                        var lastError: String? { flow.state.lastError }
                        func currentSession() async -> PaidAccessSession? { await flow.currentSession() }
                        func syncIfSubscription(_ result: VerificationResult<Transaction>,
                                                session: PaidAccessSession, generation: UUID) async -> Bool {
                            await flow.syncIfSubscription(result, session: session, generation: generation)
                        }
                    ''' + '\n'.join(entry_points) + '\n}'
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
