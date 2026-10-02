"""Prove the app-only flag selects one endpoint across the Core module boundary."""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from test_paid_access_recovery import block

ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('xcrun'), 'Apple Swift required')
class PaidEndpointTests(unittest.TestCase):
    def test_app_flag_and_both_composed_clients_use_the_same_endpoint(self):
        transport = (ROOT / 'Sources/SpeakCore/PaidAccess/PaidAccessHTTPClient.swift').read_text()
        manager = (ROOT / 'Sources/SpeakApp/PaidAccess/PaidAccessManager.swift').read_text()
        wire = (ROOT / 'Sources/SpeakApp/WireUp.swift').read_text()
        composition = wire[wire.index('    let paidClient = PaidAccessHTTPClient('):
                           wire.index('    let transcription = TranscriptionManager(')]
        core = ('import Foundation\npublic struct PaidAccessHTTPClient {\n'
                + block(transport, 'public static var defaultBaseURL:')
                + '''\npublic let baseURL: URL
                public init(baseURL: URL = Self.defaultBaseURL) { self.baseURL = baseURL }
                }''')
        app = '''import Foundation
import SpeakCore
struct AppSecureStorageSessionStore { init(storage: Int) {} }
struct PaidAccessManager {
    let client: PaidAccessHTTPClient
    init(client: PaidAccessHTTPClient, sessionStore: AppSecureStorageSessionStore, settings: Int) {
        self.client = client
    }
    func sessionProvider() -> Int { 0 }; func routerProvider() -> Int { 0 }
}
struct PaidAccessProxyClient {
    let paidClient: PaidAccessHTTPClient
    init(fallback: Int, paidClient: PaidAccessHTTPClient, sessionProvider: Int, routerProvider: Int) {
        self.paidClient = paidClient
    }
}
let secureStorage = 0, settings = 0, openRouter = 0
''' + block(manager, 'enum PaidAccessFeature') + '\n' + composition + '''
print(String(data: try JSONSerialization.data(withJSONObject: [
    paidAccess.client.baseURL.absoluteString, routedClient.paidClient.baseURL.absoluteString,
    PaidAccessHTTPClient.defaultBaseURL.absoluteString]), encoding: .utf8)!)
'''
        with tempfile.TemporaryDirectory(prefix='paid-module-boundary-') as temp:
            directory = Path(temp)
            (directory / 'Core.swift').write_text(core)
            (directory / 'App.swift').write_text(app)
            common = ['xcrun', 'swiftc', '-module-cache-path', str(directory / 'cache')]
            # Intentionally no PAID_ACCESS flag on the Core build.
            subprocess.run(common + ['-emit-library', '-emit-module', '-module-name', 'SpeakCore',
                                     str(directory / 'Core.swift'), '-o', str(directory / 'libSpeakCore.dylib')],
                           cwd=temp, capture_output=True, check=True, text=True, timeout=60)
            for enabled in [False, True]:
                binary = directory / ('internal' if enabled else 'normal')
                subprocess.run(common + (['-D', 'PAID_ACCESS'] if enabled else []) +
                               ['-I', temp, '-L', temp, '-lSpeakCore', str(directory / 'App.swift'), '-o', str(binary)],
                               capture_output=True, check=True, text=True, timeout=60)
                for override in ['', 'http://127.0.0.1:9876/staging', 'https://staging.invalid/api', 'file:///tmp/api']:
                    with self.subTest(enabled=enabled, override=override):
                        result = subprocess.run([str(binary)], env={**os.environ, 'DYLD_LIBRARY_PATH': temp,
                                                'PAID_ACCESS_BASE_URL': override}, capture_output=True, text=True,
                                                check=True, timeout=15)
                        production = 'https://api.justspeaktoit.com'
                        expected = override if enabled and override.startswith(('http:', 'https:')) else production
                        self.assertEqual(json.loads(result.stdout), [expected, expected, production])


if __name__ == '__main__':
    unittest.main()
