import Foundation
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost
import XCTest

@MainActor
extension DesktopHostOwnedDictationTests {
    func testLiveOpenFailure_NeverFeedsStartupRecoveryPCMToProvider() async throws {
        let fixture = OwnedDictationHostFixture()
        await fixture.worker.configure(
            initial: dictationPCM(Array(Int16(1)...Int16(73))), tail: Data(), openFailure: true
        )
        try await fixture.prepare()
        addTeardownBlock { try await fixture.cleanup() }
        let index = try XCTUnwrap(DesktopHostModels.all.firstIndex { DesktopHostModels.isLive($0.id) })
        await fixture.toggle(index: index)
        XCTAssertEqual(fixture.effects.live.frameCount, 0)
        XCTAssertEqual(fixture.effects.live.finishCount, 0)
        XCTAssertEqual(fixture.effects.outputCount, 0)
        let records = try await fixture.records()
        XCTAssertTrue(records[0].failure?.contains("fixture open failed after PCM") == true)
        let audio = try await fixture.audio(records[0])
        try assertDictationWAV(audio, samples: Array(Int16(1)...Int16(73)))
    }

    func testHoldShortcut_StopsOwnedRequestDespiteBusyAdmission() async throws {
        let fixture = OwnedDictationHostFixture()
        try await fixture.prepare()
        addTeardownBlock { try await fixture.cleanup() }
        let now = ProcessInfo.processInfo.systemUptime
        await fixture.host.shortcut(.init(
            input: .gesture(.holdStart), style: .holdAndDoubleTap, recognisedAt: now,
            target: "editor", targetExecutablePath: nil, textOutput: Task { FakeTextOutput() },
            modelIndex: fixture.batchIndex, deviceID: "synthetic"
        ))
        let active = try await fixture.active()
        XCTAssertEqual(active.request.trigger, .hold)
        await fixture.host.shortcut(.init(
            input: .gesture(.holdEnd), style: .holdAndDoubleTap, recognisedAt: now + 1,
            target: "later", targetExecutablePath: nil, textOutput: Task { FakeTextOutput() },
            modelIndex: fixture.batchIndex, deviceID: "later"
        ))
        let stopped = await fixture.host.ownedDictation
        XCTAssertNil(stopped)
        XCTAssertEqual(fixture.effects.transcriptions.count, 1)
    }

    func testPartialStartupFrame_FailsButPreservesAllPreviouslyAdmittedWholeSamples() async throws {
        let opening = DictationFixtureGate(open: false)
        let fixture = OwnedDictationHostFixture(worker: .init(opening: opening))
        await fixture.worker.configure(initial: dictationPCM([1, 2]), tail: Data())
        try await fixture.prepare()
        addTeardownBlock { try await fixture.cleanup() }
        let starting = Task { await fixture.toggle() }
        try await waitForDictation { await fixture.worker.opens == 1 }
        await fixture.worker.emitLate(Data([3]))
        await opening.release()
        await starting.value
        try await waitForDictation { await fixture.host.ownedDictation == nil }
        let records = try await fixture.records()
        XCTAssertTrue(records[0].failure?.contains("invalidPCM") == true)
        let audio = try await fixture.audio(records[0])
        try assertDictationWAV(audio, samples: [1, 2])
        XCTAssertNil(records[0].result)
        XCTAssertTrue(fixture.effects.transcriptions.isEmpty)
        XCTAssertEqual(fixture.effects.outputCount, 0)
    }

    func testCallerTaskCancellationDuringOpen_OwnsLateReleaseAndRecovery() async throws {
        let opening = DictationFixtureGate(open: false)
        let fixture = OwnedDictationHostFixture(worker: .init(opening: opening))
        try await fixture.prepare()
        addTeardownBlock { try await fixture.cleanup() }
        let starting = Task { await fixture.toggle() }
        try await waitForDictation { await fixture.worker.opens == 1 }
        starting.cancel()
        await opening.release()
        await starting.value
        try await waitForDictation { await fixture.host.ownedDictation == nil }
        let records = try await fixture.records()
        XCTAssertTrue(records[0].failure?.contains("startup cancelled") == true)
        let audio = try await fixture.audio(records[0])
        try assertDictationWAV(audio, samples: Array(Int16(1)...Int16(73)))
        XCTAssertTrue(fixture.effects.transcriptions.isEmpty)
        XCTAssertEqual(fixture.effects.outputCount, 0)
    }
}
