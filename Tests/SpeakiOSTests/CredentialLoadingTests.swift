#if os(iOS)
import Combine
import Foundation
import Security
import SpeakCore
import UIKit
import XCTest

@testable import SpeakiOSLib

@MainActor
final class CredentialLoadingTests: XCTestCase {
    func testFailedBootstrap_retriesWithoutChangingProviderOrPolish() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        try await fixture.seed()
        let permissions = RetryPermissions()
        let settings = fixture.settings(permissions: permissions)
        let selected = settings.selectedModel
        let failed = await settings.ensureKeysLoaded()
        XCTAssertFalse(failed)
        XCTAssertFalse(settings.credentialsAvailable)
        XCTAssertEqual(settings.selectedModel, selected)
        XCTAssertTrue(settings.postProcessingEnabled)
        XCTAssertTrue(settings.credentialFallbackReason.contains("unavailable"))
        XCTAssertFalse(fixture.defaults.bool(forKey: "hasLaunchedBefore"))

        await permissions.allow()
        let recovered = await settings.ensureKeysLoaded()
        XCTAssertTrue(recovered)
        XCTAssertEqual(settings.deepgramAPIKey, "synthetic-deepgram")
        XCTAssertEqual(settings.openRouterAPIKey, "synthetic-polish")
        XCTAssertEqual(settings.selectedModel, selected)
        XCTAssertTrue(settings.postProcessingEnabled)
        XCTAssertTrue(settings.credentialsAvailable)
    }

    func testConcurrentCallers_shareRetryAndKeepCachedKeys() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        try await fixture.seed()
        let permissions = RetryPermissions()
        await permissions.allow()
        let settings = fixture.settings(permissions: permissions)
        let values = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for _ in 0..<12 { group.addTask { await settings.ensureKeysLoaded() } }
            var result: [Bool] = []
            for await value in group { result.append(value) }
            return result
        }
        XCTAssertTrue(values.allSatisfy { $0 })
        let count = await permissions.count
        XCTAssertEqual(count, 1)
        let cached = await settings.ensureKeysLoaded()
        XCTAssertTrue(cached)
        XCTAssertEqual(settings.deepgramAPIKey, "synthetic-deepgram")
        let cachedCount = await permissions.count
        XCTAssertEqual(cachedCount, 1)
    }

    func testProtectedDataAvailability_retriesFailedBootstrap() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        try await fixture.seed()
        let permissions = RetryPermissions()
        let settings = fixture.settings(permissions: permissions, loadsSecureStorage: true)
        let failed = await settings.ensureKeysLoaded()
        XCTAssertFalse(failed)
        let loaded = expectation(description: "Protected data notification reloads credentials")
        let subscription = settings.$credentialsAvailable.filter { $0 }.sink { _ in loaded.fulfill() }
        await permissions.allow()
        NotificationCenter.default.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
        await fulfillment(of: [loaded], timeout: 3)
        subscription.cancel()
        XCTAssertEqual(settings.deepgramAPIKey, "synthetic-deepgram")
        XCTAssertEqual(settings.selectedModel, "deepgram/nova-3-streaming")
    }

    func testExistingPayloads_migrateInPlaceAndSurviveRelaunch() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let payloads = [
            "speak-app-secrets": "deepgram.apiKey=synthetic-deepgram",
            "speak-app-secrets.v2": "v2:;openrouter.apiKey=synthetic%3Bpolish"
        ]
        for (account, payload) in payloads {
            XCTAssertEqual(SecItemAdd([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: fixture.service,
                kSecAttrAccount as String: account,
                kSecValueData as String: Data(payload.utf8),
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
            ] as CFDictionary, nil), errSecSuccess)
        }
        for _ in 0..<2 {
            let permissions = RetryPermissions()
            await permissions.allow()
            let settings = fixture.settings(permissions: permissions)
            let loaded = await settings.ensureKeysLoaded()
            XCTAssertTrue(loaded)
            XCTAssertEqual(settings.openRouterAPIKey, "synthetic;polish")
            for (account, payload) in payloads {
                var result: CFTypeRef?
                XCTAssertEqual(SecItemCopyMatching([
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: fixture.service,
                    kSecAttrAccount as String: account,
                    kSecReturnAttributes as String: true,
                    kSecReturnData as String: true
                ] as CFDictionary, &result), errSecSuccess)
                let attributes = try XCTUnwrap(result as? [String: Any])
                XCTAssertEqual(attributes[kSecValueData as String] as? Data, Data(payload.utf8))
                XCTAssertEqual(
                    attributes[kSecAttrAccessible as String] as? String,
                    kSecAttrAccessibleAfterFirstUnlock as String
                )
            }
        }
    }

    func testUnavailableCredentials_blockRemoteConsumersButAllowLocalModels() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let settings = fixture.settings(permissions: RetryPermissions())
        _ = await settings.ensureKeysLoaded()
        for purpose: ModelCredentialPurpose in [.batchTranscription, .postProcessing, .liveTranscription] {
            XCTAssertThrowsError(try settings.requireAvailableCredentials(for: "openai/gpt-4o", purpose: purpose)) {
                XCTAssertTrue($0 is AppSettings.CredentialLoadingError)
                XCTAssertFalse($0.localizedDescription.contains("missing"))
                XCTAssertFalse($0.localizedDescription.contains("unlock"))
            }
        }
        XCTAssertNoThrow(try settings.requireAvailableCredentials(
            for: AppleLocalModels.foundationModelID, purpose: .postProcessing
        ))
        XCTAssertNoThrow(try settings.requireAvailableCredentials(
            for: AppleLocalModels.preferredSpeechModelID, purpose: .liveTranscription
        ))
    }

    func testWatchImport_unavailableCredentialsDoNotSpendRetryBudget() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        try await SecureStorage(configuration: .init(service: fixture.service))
            .storeSecret("synthetic-openai", identifier: AppSettings.openAIKeyID)
        let permissions = RetryPermissions()
        let settings = fixture.settings(permissions: permissions)
        settings.batchTranscriptionModel = "openai/gpt-4o-transcribe"
        settings.autoPostProcess = false
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pipeline = WatchCaptureImportPipeline(inboxDirectory: directory)
        pipeline.credentialSettings = settings
        pipeline.beginBackgroundTask = { _ in .invalid }
        var imports = 0
        var historyIDs: [UUID] = []
        pipeline.transcribeAudio = { _ in
            imports += 1
            XCTAssertEqual(settings.batchAPIKey, "synthetic-openai")
            return TranscriptionResult(
                text: "Recovered", segments: [], confidence: nil, duration: 1,
                modelIdentifier: settings.batchTranscriptionModel, cost: nil, rawPayload: nil, debugInfo: nil
            )
        }
        pipeline.persistHistory = { historyIDs.append($0.id); return true }
        let captureID = UUID()
        let audioURL = directory.appendingPathComponent("\(captureID).m4a")
        let audio = Data("synthetic audio must not be submitted".utf8)
        try audio.write(to: audioURL)
        pipeline.journal.parkJob(captureID: captureID, fileExtension: "m4a", createdAt: Date(), duration: 1)
        pipeline.journal.recordAttemptFailure(captureID: captureID, message: "Earlier transcription failure")
        let job = try XCTUnwrap(pipeline.journal.pendingJobs().first)
        // Exercise the production runImport catch and the next pass's purge.
        // More unavailable passes than the retry limit must not retire audio.
        for _ in 0...WatchCaptureImportJournal.defaultMaximumAttempts {
            await pipeline.processPendingImports()
            XCTAssertEqual(pipeline.journal.pendingJobs(), [job])
            XCTAssertTrue(pipeline.journal.isRetryable(captureID: captureID))
            XCTAssertEqual(try Data(contentsOf: audioURL), audio)
            XCTAssertTrue(pipeline.journal.pendingAcks().isEmpty)
        }
        XCTAssertEqual(imports, 0)
        await permissions.allow()
        await pipeline.processPendingImports()
        XCTAssertEqual(imports, 1)
        XCTAssertEqual(historyIDs, [captureID])
        XCTAssertEqual(settings.batchTranscriptionModel, "openai/gpt-4o-transcribe")
        XCTAssertTrue(pipeline.journal.pendingJobs().isEmpty)
        XCTAssertEqual(pipeline.journal.pendingAcks().first?.outcome, .transcribed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
        await pipeline.processPendingImports()
        XCTAssertEqual(imports, 1)
    }

    func testWatchImport_genuinelyMissingKeyStillUsesBoundedFailurePolicy() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let permissions = RetryPermissions()
        await permissions.allow()
        let settings = fixture.settings(permissions: permissions)
        settings.batchTranscriptionModel = "openai/gpt-4o-transcribe"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pipeline = WatchCaptureImportPipeline(inboxDirectory: directory)
        pipeline.credentialSettings = settings
        pipeline.beginBackgroundTask = { _ in .invalid }
        let captureID = UUID()
        let audioURL = directory.appendingPathComponent("\(captureID).m4a")
        try Data("synthetic audio never uploaded without a key".utf8).write(to: audioURL)
        pipeline.journal.parkJob(captureID: captureID, fileExtension: "m4a", createdAt: Date(), duration: 1)
        for attempt in 1...5 {
            await pipeline.processPendingImports()
            XCTAssertEqual(pipeline.journal.pendingJobs().first?.attempts, attempt)
            XCTAssertNil(pipeline.journal.pendingJobs().first?.nextRetryAt)
        }
        await pipeline.processPendingImports()
        XCTAssertTrue(settings.credentialsAvailable)
        XCTAssertTrue(pipeline.journal.pendingJobs().isEmpty)
        XCTAssertEqual(pipeline.journal.pendingAcks().first?.outcome, .failed)
    }

    func testSharedImport_unavailableCredentialsKeepInboxAndAttemptsUntouched() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let settings = fixture.settings(permissions: RetryPermissions())
        settings.batchTranscriptionModel = "openai/gpt-4o-transcribe"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = SharedRecordingInbox(root: root)
        try inbox.prepare()
        let item = SharedRecordingInboxItem(originalFilename: "memo.m4a", fileExtension: "m4a", byteCount: 5)
        let audioURL = inbox.stagedURL(id: item.id, fileExtension: item.fileExtension)
        let audio = Data("synthetic audio must not be submitted".utf8)
        try audio.write(to: audioURL)
        try inbox.commit(item)
        let importer = SharedRecordingImporter(inbox: inbox)
        importer.credentialSettings = settings
        // More unavailable passes than the retry limit must neither spend an
        // attempt nor retire the staged audio.
        for _ in 0...SharedRecordingInbox.maximumAttempts {
            await importer.drain()
            XCTAssertEqual(inbox.pending(), [item])
            XCTAssertEqual(try Data(contentsOf: audioURL), audio)
        }
        guard case .failed(let filename, let message)? = importer.lastOutcome else {
            return XCTFail("Unavailable credentials must report a failed outcome")
        }
        XCTAssertEqual(filename, "memo.m4a")
        XCTAssertTrue(message.contains("Keychain"))
    }

    func testGenuinelyMissingKeys_reportMissingAfterSuccessfulLoad() async {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let permissions = RetryPermissions()
        await permissions.allow()
        let settings = fixture.settings(permissions: permissions)
        let loaded = await settings.ensureKeysLoaded()
        XCTAssertTrue(loaded)
        XCTAssertFalse(settings.hasDeepgramKey)
        XCTAssertNoThrow(try settings.requireAvailableCredentials(
            for: "deepgram/nova-3-streaming", purpose: .liveTranscription
        ))
        XCTAssertEqual(settings.credentialFallbackReason, "no API key")
    }
}

@MainActor
private struct Fixture {
    let service = "test.credentials.\(UUID().uuidString.prefix(8))"
    let suite = "CredentialLoadingTests.\(UUID().uuidString)"
    var defaults: UserDefaults { UserDefaults(suiteName: suite)! }

    func seed() async throws {
        let storage = SecureStorage(configuration: .init(service: service))
        try await storage.storeSecret("synthetic-deepgram", identifier: AppSettings.deepgramKeyID)
        try await storage.storeSecret("synthetic-polish", identifier: AppSettings.openRouterKeyID)
    }

    func settings(permissions: RetryPermissions, loadsSecureStorage: Bool = false) -> AppSettings {
        defaults.set("deepgram/nova-3-streaming", forKey: "selectedModel")
        defaults.set(true, forKey: "postProcessingEnabled")
        return AppSettings(
            defaults: defaults,
            loadsSecureStorage: loadsSecureStorage,
            credentialStorage: SecureStorage(
                configuration: .init(service: service, accessibility: .afterFirstUnlock),
                permissionsChecker: permissions
            )
        )
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ] as CFDictionary)
    }
}

private actor RetryPermissions: KeychainPermissionsChecking {
    private var allowed = false
    private(set) var count = 0
    func allow() { allowed = true }
    func ensureKeychainAccess(forService service: String) async -> Bool {
        count += 1
        try? await Task.sleep(for: .milliseconds(40))
        return allowed
    }
}
#endif
