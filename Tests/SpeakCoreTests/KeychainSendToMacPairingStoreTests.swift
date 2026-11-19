import Foundation
import Security
import XCTest

@testable import SpeakCore

/// The Send to Mac pairing survives a relaunch through the Keychain, and
/// forgetting the Mac deletes the stored credential (#1640).
final class KeychainSendToMacPairingStoreTests: XCTestCase {
    private var configuration: SecureStorageConfiguration!

    override func setUp() {
        super.setUp()
        self.configuration = SecureStorageConfiguration(
            service: "com.justspeaktoit.tests.sendtomac.\(UUID().uuidString.prefix(8))",
            accessibility: .afterFirstUnlock
        )
    }

    override func tearDown() {
        for account in ["speak-app-secrets", "speak-app-secrets.v2", "speak-app-secrets.unsupported-backup"] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: self.configuration.service,
                kSecAttrAccount as String: account
            ]
            KeychainAccess.delete(query as CFDictionary)
        }
        self.configuration = nil
        super.tearDown()
    }

    func testPairing_persistsAcrossStoreInstances() async {
        let credential = TransportDeviceCredential(id: UUID(), secret: Data(repeating: 7, count: 32))
        let store = KeychainSendToMacPairingStore(configuration: self.configuration)
        await store.load()
        store.save(credential, forMac: "Studio Mac")
        store.setPairedMacName("Studio Mac")
        await store.flush()

        let reloaded = KeychainSendToMacPairingStore(configuration: self.configuration)
        await reloaded.load()

        XCTAssertEqual(reloaded.pairedMacName, "Studio Mac")
        XCTAssertEqual(reloaded.credential(forMac: "Studio Mac"), credential)
    }

    func testForget_removesTheStoredCredential() async {
        let store = KeychainSendToMacPairingStore(configuration: self.configuration)
        await store.load()
        store.save(TransportDeviceCredential(id: UUID(), secret: Data(repeating: 1, count: 32)), forMac: "Studio Mac")
        store.setPairedMacName("Studio Mac")
        await store.flush()

        store.removeCredential(forMac: "Studio Mac")
        store.setPairedMacName(nil)
        await store.flush()

        let reloaded = KeychainSendToMacPairingStore(configuration: self.configuration)
        await reloaded.load()
        XCTAssertNil(reloaded.pairedMacName)
        XCTAssertNil(reloaded.credential(forMac: "Studio Mac"))
        let hasSecret = await SecureStorage(configuration: self.configuration)
            .hasSecret(identifier: KeychainSendToMacPairingStore.identifier)
        XCTAssertFalse(hasSecret, "An empty pairing must not leave a Keychain item behind")
    }
}
