import Foundation
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost
import XCTest

@MainActor
extension DesktopHostOwnedDictationTests {
    func testLivePrefixIsNotSentBeforeReady_ThenFinalPCMPrecedesProviderFinish() async throws {
        let opening = DictationFixtureGate(open: false)
        let fixture = OwnedDictationHostFixture(worker: .init(opening: opening))
        await fixture.worker.configure(initial: dictationPCM([101, 102]))
        try await fixture.prepare()
        addTeardownBlock { try await fixture.cleanup() }
        let index = try XCTUnwrap(DesktopHostModels.all.firstIndex { DesktopHostModels.isLive($0.id) })
        let starting = Task { await fixture.toggle(index: index) }
        try await waitForDictation { await fixture.worker.opens == 1 }
        XCTAssertEqual(fixture.effects.live.frameCount, 0)
        XCTAssertEqual(fixture.effects.live.finishCount, 0)
        await opening.release()
        await starting.value
        await fixture.toggle(index: index)
        XCTAssertEqual(fixture.effects.live.frameSizes.reduce(0, +), 150)
        XCTAssertEqual(fixture.effects.live.finishCount, 1)
        let records = try await fixture.records()
        let audio = try await fixture.audio(records[0])
        try assertDictationWAV(audio, samples: [101, 102] + Array(Int16(1)...Int16(73)))
        XCTAssertTrue(fixture.effects.transcriptions.isEmpty)
    }

    func testRecordDuringOwnedStartup_StopsThatRequestWithoutLegacyFallbackOrFalseSuccess() async throws {
        let opening = DictationFixtureGate(open: false)
        let fixture = OwnedDictationHostFixture(worker: .init(opening: opening))
        try await fixture.prepare()
        addTeardownBlock { try await fixture.cleanup() }
        let starting = Task { await fixture.toggle() }
        try await waitForDictation { await fixture.worker.opens == 1 }
        let stopping = Task { await fixture.toggle() }
        let active = try await fixture.active()
        try await waitForDictation { await active.owner.phase == .stopping }
        await opening.release()
        await starting.value
        await stopping.value
        let opens = await fixture.worker.opens
        XCTAssertEqual(opens, 1)
        XCTAssertNil(fixture.effects.capture)
        XCTAssertTrue(fixture.effects.transcriptions.isEmpty)
        let records = try await fixture.records()
        XCTAssertTrue(records[0].failure?.contains("before capture was ready") == true)
        let audio = try await fixture.audio(records[0])
        try assertDictationWAV(audio, samples: Array(Int16(1)...Int16(73)))
    }

    func testOwnedDictation_ExcludesCaptureOnlyAdmissionUntilTerminalRelease() async throws {
        let fixture = OwnedDictationHostFixture()
        try await fixture.prepare()
        addTeardownBlock { try await fixture.cleanup() }
        await fixture.toggle()
        let active = try await fixture.active()
        do {
            _ = try await fixture.host.admitOwnedCaptureStartup(
                identity: active.request.identity,
                admission: .init(enabled: true, capability: .qualified, permission: .granted, owner: .idle),
                limits: DesktopPressCaptureBufferLimits(preRollFrames: 100, reservedFrames: 200),
                dependency: .init(worker: fixture.worker)
            )
            XCTFail("Capture-only startup cannot share a normal owned microphone.")
        } catch { XCTAssertEqual(error as? DesktopPressCaptureError, .occupied) }
        let canUseHistory = await fixture.host.canUseHistory
        XCTAssertFalse(canUseHistory)
        let opens = await fixture.worker.opens
        XCTAssertEqual(opens, 1)
        await fixture.toggle()
    }

    func testDeliveryFailureAndCleanupRetry_PreservesWAVAndLatchedFailureWithoutDoubleFinish() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("owned-delivery-\(UUID())")
        let store = try DesktopRecordingStore(directory: directory)
        let record = DesktopRecordingStore.Record(
            id: UUID(), audioFilename: "fixture.wav", modelIdentifier: "fixture/batch"
        )
        let file = try PCMRecordingFile(url: directory.appendingPathComponent(record.audioFilename))
        let worker = DictationFixtureWorker()
        await worker.configure(retirementFailures: 1)
        let request = DesktopHostOwnedDictationRequest<FakePlatform>(
            record: record,
            identity: .init(
                deviceID: "synthetic", routeID: record.modelIdentifier, profileID: "",
                sampleRate: 16_000, frameMilliseconds: 100
            ),
            profile: .defaults(modelIdentifier: record.modelIdentifier, postProcessing: .init()),
            input: .init(key: "", azureEndpoint: "", vocabulary: []),
            target: "editor", textOutput: FakeTextOutput(), trigger: .other,
            configuration: nil, tailSeconds: 0, live: nil
        )
        let owner = DesktopHostOwnedDictationSession(
            request: request, file: file,
            capability: .init(capability: .qualified, permission: .granted, makeWorker: { worker }),
            onFailure: {}, onSilence: {},
            beforePCM: { _ in throw DesktopHostError(message: "fixture delivery failed") }
        )
        let ready = await owner.start()
        XCTAssertTrue(ready)
        let unsafe = await owner.stop()
        XCTAssertNil(unsafe)
        let before = await owner.finishCount
        XCTAssertEqual(before, 0)
        let retried = await owner.stop(retry: true)
        let stopped = try XCTUnwrap(retried)
        XCTAssertTrue(stopped.record.failure?.contains("fixture delivery failed") == true)
        XCTAssertTrue(stopped.record.failure?.contains("fixture retirement failed") == true)
        try await store.save(stopped.record)
        let saved = try await store.record(id: record.id)
        XCTAssertNil(saved.result)
        try assertDictationWAV(
            directory.appendingPathComponent(record.audioFilename), samples: Array(Int16(1)...Int16(73))
        )
        let repeated = await owner.stop()
        XCTAssertEqual(repeated?.record.id, stopped.record.id)
        XCTAssertEqual(repeated?.record.failure, stopped.record.failure)
        let finishes = await owner.finishCount
        XCTAssertEqual(finishes, 1)
        try FileManager.default.removeItem(at: directory)
    }

}
