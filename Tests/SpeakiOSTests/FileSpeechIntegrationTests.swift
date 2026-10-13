#if os(iOS)
import SpeakCore
import Security
import XCTest
@testable import SpeakiOSLib

@MainActor
final class FileSpeechIntegrationTests: XCTestCase {
    func testPickerRoutingCredentialsAndAPIKeyRowsStayInParity() async throws {
        let suite = UUID().uuidString
        let service = "test.file-speech.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let storage = SecureStorage(
            configuration: .init(service: service, accessibility: .afterFirstUnlock),
            permissionsChecker: FileSpeechTestPermissions()
        )
        defer {
            defaults.removePersistentDomain(forName: suite)
            SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                           kSecAttrService as String: service] as CFDictionary)
        }
        let settings = AppSettings(defaults: defaults, loadsSecureStorage: false, credentialStorage: storage)
        settings.smallestAPIKey = "smallest-fixture"
        settings.reson8APIKey = "reson8-fixture"
        settings.stepfunAPIKey = "stepfun-fixture"
        for provider in FileSpeechProvider.allCases {
            XCTAssertTrue(AppSettings.supportedBatchModels.contains { $0.id == provider.modelID })
            XCTAssertEqual(IOSBatchTranscriptionRoute.route(for: provider.modelID), .fileSpeech(provider))
            XCTAssertEqual(settings.batchAPIKey(for: provider.modelID), "\(provider.rawValue)-fixture")
            XCTAssertTrue(settings.storedAPIKeyIdentifiers.contains(provider.metadata.apiKeyIdentifier))
            XCTAssertTrue(APIKeysView.entries(for: settings).contains { $0.id == provider.rawValue && $0.isStored })
        }
        XCTAssertTrue(AppSettings.supportedLiveModels.contains { $0.id == FileSpeechProvider.reson8LiveID })
        let route = try XCTUnwrap(LiveTranscriptionRouting.route(for: FileSpeechProvider.reson8LiveID))
        XCTAssertEqual(settings.liveAPIKey(for: route), "reson8-fixture")
        await settings.awaitPendingSecretWrites()
        for provider in FileSpeechProvider.allCases {
            let stored = try await storage.secret(identifier: provider.metadata.apiKeyIdentifier)
            XCTAssertEqual(stored, "\(provider.rawValue)-fixture")
        }
        let reloaded = AppSettings(defaults: defaults, loadsSecureStorage: false, credentialStorage: storage)
        let success = await reloaded.reloadSyncedAPIKeys()
        XCTAssertTrue(success)
        for provider in FileSpeechProvider.allCases {
            XCTAssertEqual(reloaded.batchAPIKey(for: provider.modelID), "\(provider.rawValue)-fixture")
        }
    }
}

private struct FileSpeechTestPermissions: KeychainPermissionsChecking {
    func ensureKeychainAccess(forService: String) async -> Bool { true }
}
#endif
