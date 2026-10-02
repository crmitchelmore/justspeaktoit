"""Exercise real app initialisers/StoreKit handlers against controlled boundaries.

No app graph, Apple account, Keychain, network or StoreKit service is used. The
Swift fixture substitutes only framework containers, feature inputs and external
storage/transport. Initialisers, handlers, subscription filter, session lifecycle
and entitlement/session methods come from the production files. Guard-removal
controls must fail the same executable assertions.
"""
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from test_paid_access_recovery import block

ROOT = Path(__file__).resolve().parents[2]
PLATFORMS = [
    ('mac', 'Sources/SpeakApp/PaidAccess/PaidAccessManager.swift', None, 'isEnabled'),
    ('ios', 'Sources/SpeakiOS/Services/PaidAccessStore.swift',
     'Sources/SpeakiOS/Services/PaidAccessStore+Purchase.swift', 'isAvailableOnIOS'),
]


def program(platform, path, purchase, flag, mutation=None):
    source = (ROOT / path).read_text()
    purchasing = (ROOT / purchase).read_text() if purchase else source
    initialiser = block(source, 'init(\n' if platform == 'mac' else 'init(client:')
    handler = block(purchasing, 'func handleTransactionUpdate(')
    if mutation == 'listener':
        needle = ('PaidAccessFeature.isEnabled && ' if platform == 'mac'
                  else 'if PaidAccessFeature.isAvailableOnIOS {')
        assert initialiser.count(needle) == 1
        initialiser = initialiser.replace(needle, '' if platform == 'mac' else 'if true {')
    elif mutation == 'handler':
        needle = f'guard PaidAccessFeature.{flag} else {{ return }}'
        assert handler.count(needle) == 1
        handler = handler.replace(needle, '')
    feature = block(source, 'enum PaidAccessFeature')
    # A mutable test input allows an enabled success control even though the
    # real iOS constant remains false. Production feature defaults are retained.
    feature = '@MainActor ' + feature.replace(f'static let {flag}', f'static var {flag}')
    models = (ROOT / 'Sources/SpeakCore/PaidAccess/PaidAccessClient.swift').read_text()
    lifecycle = (ROOT / 'Sources/SpeakCore/PaidAccess/PaidAccessSessionLifecycle.swift').read_text()
    sync = (ROOT / 'Sources/SpeakCore/PaidAccess/PaidStoreKitSync.swift').read_text()
    actual = '\n'.join([feature, block(models, 'public struct PaidAccessSession:'),
                        block(models, 'public protocol PaidAccessSessionStoring:'), lifecycle,
                        'enum PaidStoreKitSync {' + block(sync, 'static func entitlement(') + '}'])
    methods = [block(source, 'func ' + name) for name in
               ['currentSession()', 'clearSession()', 'refreshEntitlement()']]
    methods += [handler, block(purchasing, 'func syncIfSubscription(')]
    manager = '''@MainActor final class Manager: NSObject {
        let client: any PaidAccessClienting
        let sessions: PaidAccessSessionLifecycle
        let settings: AppSettings''' + ('\n' if platform == 'mac' else ' = AppSettings()\n') + '''
        var simpleModelChoices = false, paidRoutingEnabled = false
        var isSignedIn = false
        var entitlement = PaidEntitlement.unentitled
        var policy = PaidRoutingPolicy.unknown
        var lastError: String?
        var transactionListener: Task<Void, Never>?
        var billingChannel: PaidBillingChannel { Probe.channel }
    ''' + initialiser + '\n' + '\n'.join(methods) + '\n}'
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
    def execute(self, platform, path, purchase, flag, mutation=None):
        with tempfile.TemporaryDirectory(prefix='paid-inert-') as temp:
            source = Path(temp) / 'Inert.swift'
            source.write_text(program(platform, path, purchase, flag, mutation))
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
