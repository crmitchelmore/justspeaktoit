import Foundation
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost
import XCTest

@MainActor
extension DesktopHostOwnedDictationTests {
    func testCancelDuringOpen_RetainsPrefixAndFinalPCMWithoutSuccessfulRecording() async throws {
        let opening = DictationFixtureGate(open: false)
        let fixture = OwnedDictationHostFixture(worker: .init(opening: opening))
        await fixture.worker.configure(
            initial: dictationPCM(Array(Int16(1)...Int16(10))),
            tail: dictationPCM(Array(Int16(11)...Int16(73)))
        )
        try await fixture.prepare()
        addTeardownBlock { try await fixture.cleanup() }
        let starting = Task { await fixture.toggle() }
        try await waitForDictation { await fixture.worker.opens == 1 }
        let owner = try await fixture.active().owner
        await fixture.host.cancelTranscription()
        let before = await owner.finishCount
        XCTAssertEqual(before, 0)
        await opening.release()
        await starting.value
        try await waitForDictation { await fixture.host.ownedDictation == nil }
        let records = try await fixture.records()
        XCTAssertNil(records[0].result)
        XCTAssertTrue(records[0].failure?.contains("cancelled") == true)
        let audio = try await fixture.audio(records[0])
        try assertDictationWAV(audio, samples: Array(Int16(1)...Int16(73)))
        XCTAssertTrue(fixture.effects.transcriptions.isEmpty)
        XCTAssertEqual(fixture.effects.outputCount, 0)
    }

    func testCloseDuringOpen_ReportsRetainedOwnershipThenLateDispositionWithoutInsertion() async throws {
        let opening = DictationFixtureGate(open: false)
        let fixture = OwnedDictationHostFixture(worker: .init(opening: opening))
        try await fixture.prepare()
        addTeardownBlock { try await fixture.cleanup() }
        let starting = Task { await fixture.toggle() }
        try await waitForDictation { await fixture.worker.opens == 1 }
        let owner = try await fixture.active().owner
        let report = await fixture.host.close()
        XCTAssertFalse(report.recordingSaved)
        XCTAssertGreaterThan(report.unfinishedOperations, 0)
        let retained = await fixture.host.ownedDictation
        XCTAssertNotNil(retained)
        let earlyFinishes = await owner.finishCount
        XCTAssertEqual(earlyFinishes, 0)
        await opening.release()
        await starting.value
        try await waitForDictation { await fixture.host.ownedDictation == nil }
        let records = try await fixture.records()
        XCTAssertTrue(records[0].failure?.contains("app closed") == true)
        let audio = try await fixture.audio(records[0])
        try assertDictationWAV(audio, samples: Array(Int16(1)...Int16(73)))
        XCTAssertEqual(fixture.effects.outputCount, 0)
    }

    func testCaptureFailureAndRetirementRetry_RetainsFirstCauseAndFinishesExactlyOnce() async throws {
        let fixture = OwnedDictationHostFixture()
        await fixture.worker.configure(lateFailure: true, retirementFailures: 1)
        try await fixture.prepare()
        addTeardownBlock { try await fixture.cleanup() }
        await fixture.toggle()
        let active = try await fixture.active()
        await fixture.toggle()
        let failed = await active.owner.phase
        XCTAssertEqual(failed, .cleanupFailed)
        let before = await active.owner.finishCount
        XCTAssertEqual(before, 0)
        let canUseHistory = await fixture.host.canUseHistory
        XCTAssertFalse(canUseHistory)
        await fixture.toggle()
        let opens = await fixture.worker.opens
        XCTAssertEqual(opens, 1, "A normal Record cannot replace failed native ownership.")
        try await fixture.host.retryOwnedDictation(requestID: active.id)
        let records = try await fixture.records()
        let message = try XCTUnwrap(records[0].failure)
        let capture = try XCTUnwrap(message.range(of: "fixture final callback failed"))
        let retirement = try XCTUnwrap(message.range(of: "fixture retirement failed"))
        XCTAssertLessThan(capture.lowerBound, retirement.lowerBound)
        XCTAssertNil(records[0].result)
        let audio = try await fixture.audio(records[0])
        try assertDictationWAV(audio, samples: Array(Int16(1)...Int16(73)))
        let finishes = await active.owner.finishCount
        let retirements = await fixture.worker.retirements
        XCTAssertEqual(finishes, 1)
        XCTAssertEqual(retirements, 2)
        XCTAssertEqual(fixture.effects.outputCount, 0)
    }

    func testImmutableRequest_DoesNotRetagRouteProfileInputOrOutputAtStop() async throws {
        let fixture = OwnedDictationHostFixture()
        try await fixture.prepare()
        addTeardownBlock { try await fixture.cleanup() }
        await fixture.toggle()
        let active = try await fixture.active()
        try await fixture.host.replaceOwnedFixtureSettings()
        for model in DesktopHostModels.all {
            if let provider = DesktopHostModels.provider(for: model.id) {
                FakeLog.shared.setKey("later-key", name: provider.apiKeyIdentifier)
            }
        }
        await fixture.toggle(target: "later-field", output: "later")
        let request = try XCTUnwrap(fixture.effects.transcriptions.first)
        XCTAssertEqual(request.model, active.request.profile.modelIdentifier)
        XCTAssertEqual(request.language, active.request.profile.language)
        XCTAssertEqual(request.key, "at-start-key")
        let identities = await fixture.worker.identities
        XCTAssertEqual(identities, [active.request.identity])
        XCTAssertEqual(active.request.identity.deviceID, "original-device")
        try await waitForDictation { fixture.effects.outputCount == 1 }
        XCTAssertEqual(fixture.effects.outputJobs.first?.target, "original-field")
        XCTAssertEqual(fixture.effects.outputJobs.first?.label, "at-start")
    }

}
