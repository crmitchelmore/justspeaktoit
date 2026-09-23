import Foundation
import SpeakCore
import SpeakDesktop
import SpeakDesktopSync
import SpeakSync
import SpeakTestSupport
import XCTest

/// A sync pass through the desktop service, interrupted where the Windows host
/// can interrupt it: sign-out and another sign-in, History turned off, and
/// cancellation at shutdown, each while the pass waits between two steps.
final class DesktopCloudSyncPassTests: DesktopCloudSyncTestCase {
    func testASignInDuringAPassSendsNothingMoreInTheNewSession() async throws {
        let macID = UUID()
        seedMacHistory(server, id: macID, raw: "from account a", updatedAt: fixtureDate(50))
        let local = try await localRecording(text: "recorded on this pc")
        let gate = ChangeGate()
        let recorder = RecordingServerTransport(server: server)
        let (service, state) = try await signedInService(transport: recorder) { await gate.report($0) }

        let pass = Task { await service.sync() }
        try await eventually { await gate.isHolding }
        try await service.signOut()
        server.switchUser(to: "_synthetic-user-b")
        try await service.completeSignIn(webAuthToken: server.completeSignIn())
        let switched = await recorder.sent.count
        await gate.release()
        let report = await pass.value

        let rest = await recorder.sent.dropFirst(switched).map(\.operation)
        XCTAssertEqual(rest, [], "the pass that began for account A must send nothing in B's session")
        XCTAssertNotNil(report.error)
        let bound = await state.current.boundAccount
        XCTAssertEqual(bound, "_synthetic-user-a", "nothing is rebound before B is validated")
        // The report, which is not fenced, ran after the session ended: it
        // named only a record saved while A was current, and the cursor that
        // would have followed it was refused.
        let reported = await gate.reported
        XCTAssertEqual(reported, [.saved(macID)])
        let saved = await records.existingRecord(id: macID)
        XCTAssertNotNil(saved)
        let cursor = await state.current.historyCursor
        XCTAssertNil(cursor)

        let next = await service.sync()
        XCTAssertNil(next.error)
        let sent = await recorder.sent
        let resumed = Array(sent.dropFirst(switched))
        XCTAssertEqual(resumed.first?.operation, "public/users/caller", "B is confirmed before anything is sent")
        let feed = try XCTUnwrap(resumed.first { $0.operation == "private/changes/zone" })
        XCTAssertFalse(feed.body.contains("syncToken"), "B's feed starts from the beginning, not A's cursor")
        let rebound = await state.current.boundAccount
        XCTAssertEqual(rebound, "_synthetic-user-b")
        XCTAssertNotNil(server.recordFields(zone: syncZone, recordName: local.id.uuidString))
    }

    func testTurningHistoryOffDuringAPassStopsItBeforeItUploads() async throws {
        seedMacHistory(server, id: UUID(), raw: "from the mac", updatedAt: fixtureDate(50))
        let local = try await localRecording(text: "stays on this pc")
        let gate = ChangeGate()
        let recorder = RecordingServerTransport(server: server)
        let (service, _) = try await signedInService(transport: recorder) { await gate.report($0) }

        let pass = Task { await service.sync() }
        try await eventually { await gate.isHolding }
        try await service.setHistoryEnabled(false)
        let turnedOff = await recorder.sent.count
        await gate.release()
        let report = await pass.value

        let rest = await recorder.sent.dropFirst(turnedOff).map(\.operation)
        XCTAssertEqual(rest, [], "nothing is sent once History sync is turned off")
        XCTAssertNil(server.recordFields(zone: syncZone, recordName: local.id.uuidString))
        XCTAssertNil(report.error, "stopping as asked is not an error")
        let status = await service.status()
        XCTAssertNil(status.lastError)
    }

    func testACancelledPassAppliesNoResponseThatArrivesLate() async throws {
        let macID = UUID()
        seedMacHistory(server, id: macID, raw: "arrives after cancellation", updatedAt: fixtureDate(50))
        let recorder = RecordingServerTransport(server: server)
        await recorder.hold("private/changes/zone")
        let (service, state) = try await signedInService(transport: recorder)

        let pass = Task { await service.sync() }
        try await eventually { await recorder.heldCount == 1 }
        pass.cancel()
        await recorder.releaseHeld()
        _ = await pass.value

        let applied = await records.existingRecord(id: macID)
        XCTAssertNil(applied, "a cancelled pass saved a record its transport returned regardless")
        let cursor = await state.current.historyCursor
        XCTAssertNil(cursor, "a cancelled pass advanced its cursor")
    }

    func testATriggerDuringAPassRunsOneMoreValidatedPassAfterIt() async throws {
        seedMacHistory(server, id: UUID(), raw: "from the mac", updatedAt: fixtureDate(50))
        let gate = ChangeGate()
        let recorder = RecordingServerTransport(server: server)
        let (service, _) = try await signedInService(transport: recorder) { await gate.report($0) }

        let pass = Task { await service.sync() }
        try await eventually { await gate.isHolding }
        let trigger = await service.sync()
        XCTAssertEqual(trigger, DesktopCloudSyncReport(), "a trigger during a pass returns at once")
        await gate.release()
        let report = await pass.value

        XCTAssertNil(report.error)
        let checks = await recorder.sent.filter { $0.operation == "public/users/caller" }.count
        XCTAssertEqual(checks, 3, "the sign-in page, the pass and its follow-up each confirm the account")
    }
}
