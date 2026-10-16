import Foundation
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost
import XCTest

@MainActor
extension DesktopOwnedShortcutAdmissionTests {
    func testCloseBeforeSerializedDrain_RetainsOpeningOwnerAndCompletesLateRecovery() async throws {
        let opening = DictationFixtureGate(open: false)
        let fixture = OwnedDictationHostFixture(worker: .init(opening: opening))
        try await fixture.prepare()
        addTeardownBlock { try await fixture.cleanup() }
        let native = OwnedDictationGestureFixture(fixture)
        native.hold()
        try await waitForDictation { await fixture.worker.opens == 1 }
        let active = try await fixture.active()
        let report = await fixture.host.close()
        await native.gestures.drain()
        XCTAssertFalse(report.recordingSaved)
        XCTAssertGreaterThan(report.unfinishedOperations, 0)
        let retained = await fixture.host.dictationSessionID
        let earlyFinishes = await active.owner.finishCount
        let ready = await fixture.host.dictationSessionReady()
        XCTAssertEqual(retained, active.id)
        XCTAssertEqual(earlyFinishes, 0)
        XCTAssertFalse(ready)
        await opening.release()
        try await waitForDictation { await fixture.host.ownedDictation == nil }
        let records = try await fixture.records()
        XCTAssertTrue(records[0].failure?.contains("app closed") == true)
        XCTAssertNil(records[0].result)
        let audio = try await fixture.audio(records[0])
        try assertDictationWAV(audio, samples: Array(Int16(1)...Int16(73)))
        XCTAssertEqual(fixture.effects.outputCount, 0)
    }

    func testStopBeforeOutputResolution_CancelsTrackedAdmissionWithoutOpeningEitherRoute() async throws {
        let outputGate = DictationFixtureGate(open: false)
        let fixture = OwnedDictationHostFixture()
        try await fixture.prepare()
        addTeardownBlock {
            await outputGate.release()
            try await fixture.cleanup()
        }
        let output = Task { await outputGate.pass(); return FakeTextOutput(label: "event-output") }
        let native = OwnedDictationGestureFixture(fixture)
        native.hold(output: output)
        try await waitForDictation { await fixture.host.ownedDictationAdmission != nil }
        let admission = await fixture.host.ownedDictationAdmission
        let frozen = try XCTUnwrap(admission)
        try await fixture.host.replaceOwnedFixtureSettings()
        let canStop = await fixture.host.canStopDictationSession
        let ready = await fixture.host.dictationSessionReady()
        let owner = await fixture.host.ownedDictation
        XCTAssertTrue(canStop)
        XCTAssertFalse(ready)
        XCTAssertNil(owner)
        native.release()
        try await waitForDictation { native.deliveries.inputs.count == 2 }
        XCTAssertTrue(frozen.operation.isCancelled)
        XCTAssertEqual(frozen.snapshot.deviceID, "event-device")
        XCTAssertEqual(frozen.snapshot.key, "at-start-key")
        XCTAssertNotEqual(frozen.snapshot.profile.modelIdentifier, "later/model")
        await outputGate.release()
        await frozen.operation.value
        let opens = await fixture.worker.opens
        let records = try await fixture.records()
        let sessionID = await fixture.host.dictationSessionID
        XCTAssertEqual(opens, 0)
        XCTAssertTrue(records.isEmpty)
        XCTAssertNil(sessionID)
        XCTAssertNil(fixture.effects.capture)
        XCTAssertEqual(fixture.effects.outputCount, 0)
    }

    func testLegacySerializedAdapter_PreservesAwaitedLegacyRecordingAndStop() async throws {
        let fixture = OwnedDictationHostFixture()
        try await fixture.prepare(owned: false)
        addTeardownBlock { try await fixture.cleanup() }
        let native = OwnedDictationGestureFixture(fixture)
        native.hold()
        await native.gestures.drain()
        let trigger = await fixture.host.recording?.trigger
        let ready = await fixture.host.dictationSessionReady()
        XCTAssertEqual(trigger, .hold)
        XCTAssertTrue(ready)
        XCTAssertNotNil(fixture.effects.capture)
        native.release()
        await native.gestures.drain()
        let sessionID = await fixture.host.dictationSessionID
        let opens = await fixture.worker.opens
        XCTAssertNil(sessionID)
        XCTAssertEqual(opens, 0)
        XCTAssertEqual(fixture.effects.capture?.stopCount, 1)
        XCTAssertEqual(fixture.effects.capture?.destroyCount, 1)
        XCTAssertEqual(fixture.effects.transcriptions.count, 1)
    }
}
