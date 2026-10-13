import Foundation
import SpeakDesktop
import SpeakDesktopSync
import SpeakSync
import SpeakTestSupport
import XCTest

final class DesktopCloudSyncDeletionTests: DesktopCloudSyncTestCase {
    func testLocalDeletion_RemovesCloudCopyWithoutRestoringFetchedSnapshot() async throws {
        let recording = try await localRecording(text: "delete this synthetic record")
        let (service, _) = try await signedInService()
        let first = await service.sync()
        XCTAssertNil(first.error)
        XCTAssertNotNil(server.recordFields(zone: syncZone, recordName: recording.id.uuidString))
        try await service.deleteHistory(id: recording.id)
        let result = await service.sync()
        XCTAssertNil(result.error)
        XCTAssertNil(server.recordFields(zone: syncZone, recordName: recording.id.uuidString))
        let pending = await records.pendingCloudDeletions(account: "_synthetic-user-a")
        let deleted = await records.isDeleted(id: recording.id)
        XCTAssertTrue(pending.isEmpty)
        XCTAssertTrue(deleted)
        let reopened = try await DesktopRecordingStore(directory: records.directory)
        let saved = await reopened.existingRecord(id: recording.id)
        XCTAssertNil(saved)
    }

    func testDeletionDuringUpload_WinsAfterTheCapturedUploadCompletes() async throws {
        let recorder = RecordingServerTransport(server: server)
        let (service, _) = try await signedInService(transport: recorder)
        let prepared = await service.sync()
        XCTAssertNil(prepared.error)
        let recording = try await localRecording(text: "snapshot offered before deletion")
        await recorder.hold("private/records/modify")
        let pass = Task { await service.sync() }
        try await eventually { await recorder.heldCount == 1 }
        do {
            try await service.deleteHistory(id: recording.id)
        } catch {
            await recorder.releaseHeld()
            _ = await pass.value
            throw error
        }
        await recorder.releaseHeld()
        let result = await pass.value
        XCTAssertNil(result.error)
        XCTAssertNil(server.recordFields(zone: syncZone, recordName: recording.id.uuidString))
        let pending = await records.pendingCloudDeletions(account: "_synthetic-user-a")
        let saved = await records.existingRecord(id: recording.id)
        XCTAssertTrue(pending.isEmpty)
        XCTAssertNil(saved)
        let writes = await recorder.sent.filter { $0.operation == "private/records/modify" }
        XCTAssertTrue(writes.last?.body.contains("forceDelete") == true)
    }

    func testAccountSwitch_NeverSendsOldDeleteToAnotherAccount() async throws {
        let recording = try await localRecording(text: "account A recording")
        let recorder = RecordingServerTransport(server: server)
        let (service, _) = try await signedInService(transport: recorder)
        _ = await service.sync()
        try await service.deleteHistory(id: recording.id)
        try await service.signOut()
        server.switchUser(to: "_synthetic-user-b")
        seedMacHistory(server, id: recording.id, raw: "B owns this record", updatedAt: fixtureDate(100))
        try await service.completeSignIn(webAuthToken: server.completeSignIn())
        let switched = await recorder.sent.count
        let result = await service.sync()
        XCTAssertNil(result.error)
        let requests = await recorder.sent.dropFirst(switched)
        XCTAssertFalse(requests.contains { $0.body.contains("forceDelete") })
        XCTAssertNotNil(server.recordFields(zone: syncZone, recordName: recording.id.uuidString))
        let pendingA = await records.pendingCloudDeletions(account: "_synthetic-user-a")
        let pendingB = await records.pendingCloudDeletions(account: "_synthetic-user-b")
        let deleted = await records.isDeleted(id: recording.id)
        XCTAssertEqual(pendingA.count, 1)
        XCTAssertTrue(pendingB.isEmpty)
        XCTAssertTrue(deleted, "Rebinding account state cannot erase local deletion intent")
    }

    func testHistoryDisabled_LocalDeleteDoesNotGrantLaterCloudDeleteConsent() async throws {
        let recording = try await localRecording(text: "local-only deletion")
        let (service, _) = try await signedInService()
        _ = await service.sync()
        try await service.setHistoryEnabled(false)
        try await service.deleteHistory(id: recording.id)
        let disabled = await service.sync()
        XCTAssertNil(disabled.error)
        try await service.setHistoryEnabled(true)
        let enabled = await service.sync()
        XCTAssertNil(enabled.error)
        XCTAssertNotNil(server.recordFields(zone: syncZone, recordName: recording.id.uuidString))
        let pending = await records.pendingCloudDeletions(account: "_synthetic-user-a")
        let visible = await records.existingRecord(id: recording.id)
        XCTAssertTrue(pending.isEmpty)
        XCTAssertNil(visible, "Opting back in must not resurrect locally deleted History")
    }

    func testFailedCloudDelete_SurvivesRelaunchAndRetries() async throws {
        let recording = try await localRecording(text: "retry cloud deletion")
        let transport = FailingDeletionTransport(server: server)
        let (service, _) = try await signedInService(transport: transport)
        _ = await service.sync()
        try await service.deleteHistory(id: recording.id)
        let failed = await service.sync()
        XCTAssertNotNil(failed.error)
        let pending = await records.pendingCloudDeletions(account: "_synthetic-user-a")
        XCTAssertEqual(pending.count, 1)
        let reopened = try await DesktopRecordingStore(directory: records.directory)
        records = reopened
        let (next, _) = try makeService()
        await next.prepare()
        let retried = await next.sync()
        XCTAssertNil(retried.error)
        XCTAssertNil(server.recordFields(zone: syncZone, recordName: recording.id.uuidString))
        let finished = await reopened.pendingCloudDeletions(account: "_synthetic-user-a")
        XCTAssertTrue(finished.isEmpty)
    }

    func testLateRemoteResurrection_IsDeletedAgainOnlyInItsOriginalAccount() async throws {
        let recording = try await localRecording(text: "stale device snapshot")
        let (service, _) = try await signedInService()
        _ = await service.sync()
        try await service.deleteHistory(id: recording.id)
        _ = await service.sync()
        seedMacHistory(server, id: recording.id, raw: "late remote save", updatedAt: fixtureDate(150))
        let reconciled = await service.sync()
        XCTAssertNil(reconciled.error)
        XCTAssertNil(server.recordFields(zone: syncZone, recordName: recording.id.uuidString))
        let visible = await records.existingRecord(id: recording.id)
        XCTAssertNil(visible)
    }

    func testConsentDisabledDuringDelete_LeavesItsTicketForAnExplicitOptIn() async throws {
        try await interruptedDeletion(cancel: false)
    }

    func testCancelledDelete_DoesNotAcknowledgeItsLateResponse() async throws {
        try await interruptedDeletion(cancel: true)
    }

    private func interruptedDeletion(cancel: Bool) async throws {
        let recording = try await localRecording(text: "interrupted deletion")
        let recorder = RecordingServerTransport(server: server)
        let (service, _) = try await signedInService(transport: recorder)
        let initial = await service.sync()
        XCTAssertNil(initial.error)
        try await service.deleteHistory(id: recording.id)
        await recorder.hold("private/records/modify")
        let pass = Task { await service.sync() }
        try await eventually { await recorder.heldCount == 1 }
        if cancel {
            pass.cancel()
        } else {
            try await service.setHistoryEnabled(false)
        }
        await recorder.releaseHeld()
        _ = await pass.value
        let pending = await records.pendingCloudDeletions(account: "_synthetic-user-a")
        XCTAssertEqual(pending.count, 1, "An inadmissible response must not acknowledge the durable ticket")
        let retained = await records.existingRecord(id: recording.id)
        XCTAssertNil(retained)
        try await service.setHistoryEnabled(true)
        let resumed = await service.sync()
        XCTAssertNil(resumed.error)
        let completed = await records.pendingCloudDeletions(account: "_synthetic-user-a")
        XCTAssertTrue(completed.isEmpty)
    }
}

private actor FailingDeletionTransport: CloudKitWebServicesHTTPTransport {
    let server: FakeCloudKitWebServer

    init(server: FakeCloudKitWebServer) { self.server = server }

    func send(
        _ request: CloudKitWebServicesHTTPRequest,
        responseLimit: Int
    ) async throws -> CloudKitWebServicesHTTPResponse {
        if request.body.flatMap({ String(data: $0, encoding: .utf8) })?.contains("forceDelete") == true {
            throw URLError(.notConnectedToInternet)
        }
        let response = server.handle(method: request.method, url: request.url, body: request.body)
        return CloudKitWebServicesHTTPResponse(
            statusCode: response.status, headers: response.headers, body: response.body
        )
    }
}
