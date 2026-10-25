import Foundation
import XCTest

@testable import SpeakCore

final class SharedSettingsTransferPolicyTests: XCTestCase {
    func testSharedPreferenceNames_DoNotExpandTheTransferPolicy() async throws {
        let suite = "SharedSettingsTransfer.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = SecureStorage(
            configuration: SecureStorageConfiguration(service: suite),
            permissionsChecker: RefuseTransferKeychainAccess()
        )
        let manager = ConfigTransferManager(pbkdf2Iterations: 1_000)
        let localKeys: [ApplicationPreferenceKey] = [
            .batchTranscriptionModel, .postProcessingModel, .preferredLocale,
            .postProcessingEnabled, .handsFreeDictationEnabled
        ]
        for key in localKeys {
            defaults.set("Existing local value", forKey: key.rawValue)
            let payload = ConfigTransferPayload(secrets: [:], settings: [key.rawValue: "Incoming value"])
            do {
                try await manager.applyImport(payload: payload, storage: storage, defaults: defaults)
                XCTFail("Sharing a preference name must not enable config transfer: \(key.rawValue)")
            } catch {
                XCTAssertEqual(error as? ConfigTransferError, .unknownSettingKey(key.rawValue))
            }
            XCTAssertEqual(defaults.string(forKey: key.rawValue), "Existing local value")
        }
    }

}

private struct RefuseTransferKeychainAccess: KeychainPermissionsChecking {
    func ensureKeychainAccess(forService service: String) async -> Bool { false }
}
