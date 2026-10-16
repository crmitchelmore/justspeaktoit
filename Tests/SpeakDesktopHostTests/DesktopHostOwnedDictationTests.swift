import Foundation
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost
import XCTest

@MainActor
final class OwnedDictationHostFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("owned-dictation-\(UUID())")
    let effects = TailEffects()
    let worker: DictationFixtureWorker
    var host: DesktopHostController<FakePlatform>!
    var batchIndex = 0

    init(worker: DictationFixtureWorker = .init()) { self.worker = worker }

    func prepare(owned: Bool = true, qualified: Bool = true) async throws {
        FakeLog.shared.reset()
        DesktopHostModels.configure(streamingQualified: true)
        for model in DesktopHostModels.all {
            if let provider = DesktopHostModels.provider(for: model.id) {
                FakeLog.shared.setKey("at-start-key", name: provider.apiKeyIdentifier)
            }
        }
        let worker = worker
        let capability = DesktopHostOwnedDictationCapability(
            capability: qualified ? .qualified : .unavailable("fixture not qualified"),
            permission: .granted, makeWorker: { worker }
        )
        host = try DesktopHostController(
            directory: directory, effects: effects, shutdownGrace: .milliseconds(30),
            ownedDictationCapability: owned ? capability : nil
        )
        await host.markReadyForSelfTest()
        batchIndex = try XCTUnwrap(DesktopHostModels.all.firstIndex {
            DesktopTranscription.provider(for: $0.id) != nil
        })
        let configuration = try DesktopConfiguration(values: ["postRecordingTailDuration": AnyCodable(.double(0))])
        try await host.saveConfiguration(configuration.entries)
    }

    func toggle(index: Int? = nil, target: String = "original-field", output: String = "at-start") async {
        await host.toggle(
            target: target, modelIndex: index ?? batchIndex, deviceID: "original-device",
            targetExecutablePath: nil, textOutput: FakeTextOutput(label: output)
        )
    }

    func records() async throws -> [DesktopRecordingStore.Record] { try await host.store.records() }

    func active() async throws -> DesktopHostOwnedDictationHandle<FakePlatform> {
        let active = await host.ownedDictation
        return try XCTUnwrap(active)
    }

    func audio(_ record: DesktopRecordingStore.Record) async throws -> URL {
        try await host.store.audioURL(for: record)
    }

    func cleanup() async throws {
        await worker.opening.release()
        await worker.quiescing.release()
        await worker.retiring.release()
        await worker.clearRetirementFailure()
        await host?.close()
        if let active = await host?.ownedDictation {
            await active.stop?.value
            if await host.ownedDictation?.failure != nil { try await host.retryOwnedDictation(requestID: active.id) }
        }
        try await waitForDictation { await self.host.ownedDictation == nil }
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
}

extension DesktopHostController where Platform == FakePlatform {
    func replaceOwnedFixtureSettings() throws {
        settings.model = "later/model"
        settings.microphoneDeviceID = "later-device"
        settings.textOutput = FakeTextOutput(label: "later")
        settings.configuration = try DesktopConfiguration(values: [
            "postRecordingTailDuration": AnyCodable(.double(1.5)),
            "preferredLocale": AnyCodable(.string("fr-FR"))
        ])
        profiles.removeAll()
    }
}

@MainActor
final class DesktopHostOwnedDictationTests: XCTestCase {
    func testAbsentCapability_UsesUnchangedLegacyCapture() async throws {
        let fixture = OwnedDictationHostFixture()
        try await fixture.prepare(owned: false)
        addTeardownBlock { try await fixture.cleanup() }
        await fixture.toggle()
        XCTAssertNotNil(fixture.effects.capture)
        let owned = await fixture.host.ownedDictation
        XCTAssertNil(owned)
        await fixture.toggle()
        XCTAssertEqual(fixture.effects.capture?.stopCount, 1)
        XCTAssertEqual(fixture.effects.capture?.destroyCount, 1)
        let opens = await fixture.worker.opens
        XCTAssertEqual(opens, 0)
    }

    func testUnqualifiedCapability_ReportsFailureWithoutOpeningEitherRoute() async throws {
        let fixture = OwnedDictationHostFixture()
        try await fixture.prepare(qualified: false)
        addTeardownBlock { try await fixture.cleanup() }
        await fixture.toggle()
        XCTAssertNil(fixture.effects.capture)
        let opens = await fixture.worker.opens
        XCTAssertEqual(opens, 0)
        let records = try await fixture.records()
        XCTAssertTrue(records.isEmpty)
        XCTAssertTrue(FakeLog.shared.allStatuses.last?.contains("fixture not qualified") == true)
        XCTAssertTrue(fixture.effects.transcriptions.isEmpty)
    }

    func testOwnedStop_IncludesFinal73SamplesAndReusesRealBatchOutputOnce() async throws {
        let quiescing = DictationFixtureGate(open: false)
        let fixture = OwnedDictationHostFixture(worker: .init(quiescing: quiescing))
        try await fixture.prepare()
        addTeardownBlock { try await fixture.cleanup() }
        await fixture.toggle()
        let owner = try await fixture.active().owner
        let stopping = Task { await fixture.toggle(target: "later-field", output: "later") }
        try await waitForDictation { await fixture.worker.quiescences == 1 }
        let earlyFinishes = await owner.finishCount
        XCTAssertEqual(earlyFinishes, 0)
        XCTAssertTrue(fixture.effects.transcriptions.isEmpty)
        XCTAssertNil(fixture.effects.capture, "Owned dictation never starts the legacy microphone/WAV.")
        await quiescing.release()
        await stopping.value
        try await waitForDictation { fixture.effects.outputCount == 1 }
        XCTAssertEqual(fixture.effects.transcriptions.count, 1)
        XCTAssertEqual(fixture.effects.transcriptions[0].duration, 73.0 / 16_000, accuracy: 0.000001)
        XCTAssertEqual(fixture.effects.outputJobs.first?.target, "original-field")
        XCTAssertEqual(fixture.effects.outputJobs.first?.label, "at-start")
        let records = try await fixture.records()
        XCTAssertEqual(records.count, 1)
        let audio = try await fixture.audio(records[0])
        try assertDictationWAV(audio, samples: Array(Int16(1)...Int16(73)))
        let finishes = await owner.finishCount
        XCTAssertEqual(finishes, 1)
    }

    func testOpenEmits73SamplesThenThrows_FailedHistoryHasExactWAVAndNoTranscription() async throws {
        let fixture = OwnedDictationHostFixture()
        await fixture.worker.configure(
            initial: dictationPCM(Array(Int16(1)...Int16(73))), tail: Data(), openFailure: true
        )
        try await fixture.prepare()
        addTeardownBlock { try await fixture.cleanup() }
        await fixture.toggle()
        let records = try await fixture.records()
        XCTAssertEqual(records.count, 1)
        XCTAssertNil(records[0].result)
        XCTAssertNil(records[0].recordedDuration)
        XCTAssertTrue(records[0].failure?.contains("fixture open failed after PCM") == true)
        let audio = try await fixture.audio(records[0])
        try assertDictationWAV(audio, samples: Array(Int16(1)...Int16(73)))
        XCTAssertTrue(fixture.effects.transcriptions.isEmpty)
        XCTAssertEqual(fixture.effects.outputCount, 0)
        let counts = await (fixture.worker.opens, fixture.worker.quiescences, fixture.worker.retirements)
        XCTAssertEqual(counts.0, 1)
        XCTAssertEqual(counts.1, 1)
        XCTAssertEqual(counts.2, 1)
    }

}
