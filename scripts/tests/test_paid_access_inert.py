"""Exercise real app initialisers/StoreKit handlers against controlled boundaries.

No app graph, Apple account, Keychain, network or StoreKit service is used. The
Swift fixture substitutes only framework containers, feature inputs and external
storage/transport. The platform initialisers (which own the StoreKit listener and
its feature guards), the shared PaidAccessFlow handler, subscription filter,
session lifecycle and entitlement/session methods come from the production
files. Guard-removal controls must fail the same executable assertions.
"""
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from test_paid_access_recovery import block
from test_paid_access_session_boundaries import shared_flow

ROOT = Path(__file__).resolve().parents[2]
PLATFORMS = [
    ('mac', 'Sources/SpeakApp/PaidAccess/PaidAccessManager.swift', 'isEnabled'),
    ('ios', 'Sources/SpeakiOS/Services/PaidAccessStore.swift', 'isAvailableOnIOS'),
]


def program(platform, path, flag, mutation=None):
    source = (ROOT / path).read_text()
    initialiser = block(source, 'init(\n' if platform == 'mac' else 'init(client:')
    if mutation == 'listener':
        needle = ('PaidAccessFeature.isEnabled && ' if platform == 'mac'
                  else 'if PaidAccessFeature.isAvailableOnIOS {')
        assert initialiser.count(needle) == 1
        initialiser = initialiser.replace(needle, '' if platform == 'mac' else 'if true {')
    elif mutation == 'handler':
        # Each platform admits updates into the shared, flag-free flow handler
        # only while its own feature flag is still on.
        needle = f'guard PaidAccessFeature.{flag} else {{ continue }}'
        assert initialiser.count(needle) == 1
        initialiser = initialiser.replace(needle, '')
    feature = block(source, 'enum PaidAccessFeature')
    # A mutable test input allows an enabled success control even though the
    # real iOS constant remains false. Production feature defaults are retained.
    feature = '@MainActor ' + feature.replace(f'static let {flag}', f'static var {flag}')
    models = (ROOT / 'Sources/SpeakCore/PaidAccess/PaidAccessClient.swift').read_text()
    lifecycle = (ROOT / 'Sources/SpeakCore/PaidAccess/PaidAccessSessionLifecycle.swift').read_text()
    sync = (ROOT / 'Sources/SpeakCore/PaidAccess/Apple/PaidStoreKitSync.swift').read_text()
    actual = '\n'.join([feature, block(models, 'public struct PaidAccessSession:'),
                        block(models, 'public protocol PaidAccessSessionStoring:'), lifecycle,
                        'enum PaidStoreKitSync {' + block(sync, 'static func entitlement(') + '}',
                        shared_flow()])
    # Only the macOS owner keeps its own client and injected settings.
    stored = ('let client: any PaidAccessClienting\n        let settings: AppSettings\n'
              if platform == 'mac' else '')
    manager = '''@MainActor final class Manager: NSObject {
        let flow: PaidAccessFlow
        ''' + stored + '''
        var simpleModelChoices = false, paidRoutingEnabled = false
        var entitlement = PaidEntitlement.unentitled
        var policy = PaidRoutingPolicy.unknown
        var isSignedIn = false, isBusy = false
        var lastError: String?
        var products: [Product] = []
        var transactionListener: Task<Void, Never>?
        var billingChannel: PaidBillingChannel { Probe.channel }
    ''' + initialiser + '\n' + block(source, 'func publish(') + '\n}'
    create = ('Manager(client: client, sessionStore: store, settings: AppSettings())'
              if platform == 'mac' else 'Manager(client: client, sessionStore: store)')
    fixture = (ROOT / 'scripts/tests/fixtures/paid-access-inert.swift').read_text()
    return (fixture.replace('// PRODUCTION inserted here.', actual + '\n' + manager)
            .replace('FEATURE_FLAG', flag).replace('MAKE_MANAGER', create)
            .replace('IS_MAC', 'true' if platform == 'mac' else 'false'))

class PaidShippingEntitlementsTests(unittest.TestCase):
    def test_ordinary_shipping_entitlements_do_not_enable_paid_identity(self):
        for path in ['Config/SpeakMacOS.entitlements', 'Config/SpeakMacOS.AppStore.entitlements',
                     'SpeakiOS.entitlements']:
            with self.subTest(path=path):
                self.assertNotIn('com.apple.developer.applesignin',
                                 plistlib.loads((ROOT / path).read_bytes()))


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('xcrun'), 'Apple Swift required')
class PaidAutomaticInactivityTests(unittest.TestCase):
    def execute(self, platform, path, flag, mutation=None):
        with tempfile.TemporaryDirectory(prefix='paid-inert-') as temp:
            source = Path(temp) / 'Inert.swift'
            source.write_text(program(platform, path, flag, mutation))
            binary = Path(temp) / 'inert'
            result = subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library',
                                     '-module-cache-path', str(Path(temp) / 'cache'),
                                     str(source), '-o', str(binary)],
                                    capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stderr)
            return subprocess.run([str(binary)], capture_output=True, text=True, timeout=30)

    def test_actual_disabled_paths_and_enabled_subscription_controls(self):
        for platform in PLATFORMS:
            with self.subTest(platform=platform[0]):
                result = self.execute(*platform)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn('automatic StoreKit controls passed', result.stdout)

    def test_each_guard_is_required_by_executable_off_path_controls(self):
        for platform in PLATFORMS:
            for mutation in ['listener', 'handler']:
                with self.subTest(platform=platform[0], removed=mutation):
                    result = self.execute(*platform, mutation=mutation)
                    self.assertNotEqual(result.returncode, 0, 'removed guard survived')
                    expected = ('disabled listener was created' if mutation == 'listener'
                                else 'disabled handler accessed paid state')
                    self.assertIn(expected, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
