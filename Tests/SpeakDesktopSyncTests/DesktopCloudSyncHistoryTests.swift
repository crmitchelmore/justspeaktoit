import Foundation
import SpeakCore
import SpeakDesktop
import SpeakDesktopSync
import SpeakSync
import SpeakTestSupport
import XCTest

final class DesktopCloudSyncHistoryTests: DesktopCloudSyncTestCase {
    // MARK: - Configuration

    func testWithoutAnAPITokenSyncIsUnavailableAndSaysWhy() async throws {
        let resolution = DesktopCloudSyncConfiguration.resolve(
            buildToken: nil, buildEnvironment: "production", processEnvironment: [:], train: .stable
        )
        guard case .unavailable(let reason) = resolution else { return XCTFail("Expected unavailable") }
        XCTAssertTrue(reason.contains("CloudKit API token"))

        let state = try DesktopCloudSyncStateStore(url: directory.appendingPathComponent("cloud-sync.json"))
        let service = DesktopCloudSyncService(
            resolution: resolution, transport: FakeServerTransport(server: server), vault: vault, state: state,
            historyStore: DesktopHistorySyncStore(records: records, state: state), cryptography: nil
        )
        let status = await service.status()
        XCTAssertEqual(status.unavailableReason, reason)
        XCTAssertEqual(status.summary, reason)
        let report = await service.sync()
        XCTAssertEqual(report.error, reason)
        XCTAssertTrue(server.requestLog.isEmpty, "Nothing is sent without a configuration")
    }

    func testTheMacContainerIsUsedAndARuntimeOverrideWins() throws {
        let built = DesktopCloudSyncConfiguration.resolve(
            buildToken: "built", buildEnvironment: "production", processEnvironment: [:], train: .stable
        )
        XCTAssertEqual(built.configuration?.containerIdentifier, "iCloud.com.justspeaktoit")
        XCTAssertEqual(built.configuration?.environment, .production)
        XCTAssertEqual(built.configuration?.apiToken, "built")

        let overridden = DesktopCloudSyncConfiguration.resolve(
            buildToken: "built", buildEnvironment: "production",
            processEnvironment: [
                "JSTI_CLOUDKIT_WEB_API_TOKEN": "developer",
                "JSTI_CLOUDKIT_WEB_ENVIRONMENT": "development"
            ],
            train: .alpha
        )
        XCTAssertEqual(overridden.configuration?.apiToken, "developer")
        XCTAssertEqual(overridden.configuration?.environment, .development)
        XCTAssertEqual(overridden.configuration?.containerIdentifier, "iCloud.com.justspeaktoit.alpha")
        // Neither the build nor the process environment can move the endpoint
        // that receives both tokens.
        XCTAssertEqual(built.configuration?.baseURL, CloudKitWebServicesConfiguration.defaultBaseURL)
        XCTAssertEqual(overridden.configuration?.baseURL, CloudKitWebServicesConfiguration.defaultBaseURL)

        let wrong = DesktopCloudSyncConfiguration.resolve(
            buildToken: "built", buildEnvironment: "staging", processEnvironment: [:], train: .stable
        )
        XCTAssertNil(wrong.configuration)
    }

    func testTheSignInCallbackAndPageAreStrictlyChecked() throws {
        XCTAssertEqual(DesktopCloudSyncSignIn.callbackURL, "http://127.0.0.1:47823/cloudkit-sign-in")
        XCTAssertEqual(
            DesktopCloudSyncSignIn.webAuthToken(fromRequestTarget: "/cloudkit-sign-in?ckWebAuthToken=abc%2Bdef%3D"),
            "abc+def="
        )
        XCTAssertNil(DesktopCloudSyncSignIn.webAuthToken(fromRequestTarget: "/other?ckWebAuthToken=abc"))
        XCTAssertNil(DesktopCloudSyncSignIn.webAuthToken(fromRequestTarget: "/cloudkit-sign-in"))
        func trusted(_ text: String) throws -> Bool {
            DesktopCloudSyncSignIn.isTrustedSignInURL(try XCTUnwrap(URL(string: text)))
        }
        XCTAssertTrue(try trusted(FakeCloudKitWebServer.signInURL))
        XCTAssertFalse(try trusted("http://idmsa.apple.com/x"))
        XCTAssertFalse(try trusted("https://apple.com.example/x"))
    }

    // MARK: - History

    func testMacHistoryAppearsOnWindowsAndWindowsHistoryReachesTheMac() async throws {
        let macID = UUID()
        seedMacHistory(server, id: macID, raw: "hello from mac", processed: "Hello from Mac.",
                       updatedAt: fixtureDate(50))
        let local = try await localRecording(text: "hello from windows")
        let changes = ChangeLog()
        let (service, _) = try await signedInService { await changes.append($0) }

        let report = await service.sync()

        XCTAssertNil(report.error)
        let synced = try await records.record(id: macID)
        XCTAssertTrue(synced.isSyncedCopy)
        XCTAssertEqual(synced.originPlatform, "macos")
        XCTAssertEqual(synced.audioFilename, "", "Audio never leaves the Mac")
        XCTAssertEqual(synced.result?.text, "hello from mac")
        XCTAssertEqual(synced.displayText, "Hello from Mac.")
        XCTAssertEqual(synced.createdAt, fixtureDate(0))
        let applied = await changes.all
        XCTAssertEqual(applied, [.saved(macID)])

        let uploaded = try XCTUnwrap(server.recordFields(zone: syncZone, recordName: local.id.uuidString))
        XCTAssertEqual(uploaded["originPlatform"]?.value as? String, "windows")
        XCTAssertEqual(uploaded["rawTranscription"]?.value as? String, "hello from windows")
        XCTAssertEqual(uploaded["wordCount"]?.value as? Int, 3)

        let writes = server.requestLog.filter { $0 == "private/records/modify" }.count
        _ = await service.sync()
        XCTAssertEqual(server.requestLog.filter { $0 == "private/records/modify" }.count, writes,
                       "An unchanged History does not upload again")
    }

    func testALocalEditUploadsAgainWithANewerTimestamp() async throws {
        var local = try await localRecording(text: "first draft")
        let (service, _) = try await signedInService()
        _ = await service.sync()

        local.processedText = "First draft, tidied."
        try await records.save(local)
        _ = await service.sync()

        let fields = try XCTUnwrap(server.recordFields(zone: syncZone, recordName: local.id.uuidString))
        XCTAssertEqual(fields["postProcessedText"]?.value as? String, "First draft, tidied.")
        let stored = fields["updatedAt"]?.value
        let updatedAt = try XCTUnwrap(stored as? Int64 ?? (stored as? Int).map(Int64.init))
        XCTAssertGreaterThan(updatedAt, milliseconds(local.createdAt))
    }

    func testADeletionOnTheMacRemovesSyncedCopiesButKeepsWindowsRecordings() async throws {
        let macID = UUID()
        seedMacHistory(server, id: macID, raw: "mac", updatedAt: fixtureDate(50))
        let local = try await localRecording(text: "windows take")
        let changes = ChangeLog()
        let (service, _) = try await signedInService { await changes.append($0) }
        _ = await service.sync()

        server.seedDeletion(zone: syncZone, recordName: macID.uuidString)
        server.seedDeletion(zone: syncZone, recordName: local.id.uuidString)
        _ = await service.sync()

        let removed = await records.existingRecord(id: macID)
        XCTAssertNil(removed)
        let kept = try await records.record(id: local.id)
        XCTAssertEqual(kept.audioFilename, "take.wav", "A recording made here keeps its audio")
        let applied = await changes.all
        XCTAssertEqual(applied.suffix(2), [.removed(macID), .keptAfterRemoteDeletion(local.id)])

        _ = await service.sync()
        XCTAssertNil(server.recordFields(zone: syncZone, recordName: local.id.uuidString),
                     "A recording deleted on the Mac is never uploaded again")
    }

    func testANewerMacEditUpdatesTextButKeepsWindowsAudioAndModel() async throws {
        let local = try await localRecording(text: "original words")
        let (service, _) = try await signedInService()
        _ = await service.sync()

        var fields = try XCTUnwrap(server.recordFields(zone: syncZone, recordName: local.id.uuidString))
        fields["postProcessedText"] = ("Edited on the Mac.", "STRING")
        fields["updatedAt"] = (milliseconds(Date(timeIntervalSince1970: 2_000_000_000)), "TIMESTAMP")
        server.seedRecord(
            zone: syncZone, recordName: local.id.uuidString, recordType: "TranscriptionHistory", fields: fields
        )
        _ = await service.sync()

        let updated = try await records.record(id: local.id)
        XCTAssertEqual(updated.displayText, "Edited on the Mac.")
        XCTAssertEqual(updated.result?.text, "original words")
        XCTAssertEqual(updated.audioFilename, "take.wav")
        XCTAssertFalse(updated.isSyncedCopy)
    }

    func testAnotherAppleIDGetsThisDevicesHistoryUploadedAfresh() async throws {
        let local = try await localRecording(text: "belongs to this pc")
        let (service, state) = try await signedInService()
        _ = await service.sync()
        let firstUser = await state.current.boundAccount
        XCTAssertEqual(firstUser, "_synthetic-user-a")

        server.switchUser(to: "_synthetic-user-b")
        try await service.completeSignIn(webAuthToken: server.completeSignIn())
        let before = server.requestLog.filter { $0 == "private/records/modify" }.count
        let report = await service.sync()

        XCTAssertNil(report.error)
        let bound = await state.current.boundAccount
        XCTAssertEqual(bound, "_synthetic-user-b")
        XCTAssertGreaterThan(server.requestLog.filter { $0 == "private/records/modify" }.count, before)
        XCTAssertNotNil(server.recordFields(zone: syncZone, recordName: local.id.uuidString))
    }

    func testAnExpiredSessionSignsOutAndAsksToSignInAgain() async throws {
        let (service, _) = try await signedInService()
        server.expireSessions()

        let report = await service.sync()

        XCTAssertNotNil(report.error)
        let status = await service.status()
        XCTAssertFalse(status.isSignedIn)
        XCTAssertNil(try vault.readCredential(DesktopCloudSyncCredential.webAuthToken))
        let page = try await service.signInPage()
        XCTAssertNotNil(page)
    }

    func testRecoveryLeavesSyncedCopiesAlone() async throws {
        var copy = DesktopRecordingStore.Record(
            syncedID: UUID(), createdAt: fixtureDate(0),
            modelIdentifier: "deepgram/nova-3", originPlatform: "macos"
        )
        copy.processedText = "Processed only."
        try await records.save(copy)

        let report = try await records.recoverInterruptedRecordings()

        let recovered = try XCTUnwrap(report.records.first { $0.id == copy.id })
        XCTAssertNil(recovered.failure)
        XCTAssertEqual(recovered.displayText, "Processed only.")
        let removedCopy = try await records.removeSyncedCopy(id: copy.id)
        XCTAssertTrue(removedCopy)
        let local = try await localRecording(text: "mine")
        let removedLocal = try await records.removeSyncedCopy(id: local.id)
        XCTAssertFalse(removedLocal)
        let kept = await records.existingRecord(id: local.id)
        XCTAssertNotNil(kept)
    }
}
