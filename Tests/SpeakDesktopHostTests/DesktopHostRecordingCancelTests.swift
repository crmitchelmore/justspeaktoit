import Foundation
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost
import XCTest

final class DesktopHostRecordingCancelTests: XCTestCase {
    private var directory: URL!
    private var controller: DesktopHostController<FakePlatform>!
    private var effects: RecordingCancelEffects!
    private var modelIndex = 0

    override func setUp() async throws {
        FakeLog.shared.reset()
        DesktopHostModels.configure(streamingQualified: false)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("recording-cancel-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        effects = RecordingCancelEffects()
        controller = try DesktopHostController<FakePlatform>(directory: directory, effects: effects)
        await controller.markReadyForSelfTest()
        modelIndex = try XCTUnwrap(
            DesktopHostModels.all.firstIndex { DesktopTranscription.provider(for: $0.id) != nil }
        )
        let model = DesktopHostModels.all[modelIndex].id
        let key = try XCTUnwrap(DesktopHostModels.provider(for: model)).apiKeyIdentifier
        FakeLog.shared.setKey("synthetic-key", name: key)
    }

    override func tearDown() async throws {
        await controller.close()
        try FileManager.default.removeItem(at: directory)
        DesktopHostModels.configure(streamingQualified: true)
    }

    private func start() async {
        await controller.toggle(
            target: "editor", modelIndex: modelIndex, deviceID: "", targetExecutablePath: nil,
            textOutput: FakeTextOutput()
        )
    }

    private func records() async throws -> [DesktopRecordingStore.Record] {
        try await DesktopRecordingStore(directory: directory.appendingPathComponent("History")).records()
    }

    func testCancellingDuringLegacyCaptureStopsAndRetainsAudioWithoutTranscriptionOrOutput() async throws {
        await start()
        let active = await controller.recording?.record.id
        XCTAssertNotNil(active)
        await controller.cancelTranscription()
        let remaining = await controller.recording?.record.id
        XCTAssertNil(remaining)
        let saved = try await records()
        let record = try XCTUnwrap(saved.first)
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(record.failure, "Recording cancelled. Audio retained.")
        XCTAssertNil(record.result)
        XCTAssertEqual(effects.stops, 1)
        XCTAssertEqual(effects.destructions, 1)
        XCTAssertEqual(effects.transcriptions, 0)
        XCTAssertTrue(effects.outputs.isEmpty)
        let audio = directory.appendingPathComponent("History").appendingPathComponent(record.audioFilename)
        XCTAssertGreaterThan(try Data(contentsOf: audio).count, 44)
    }

    func testRecordingCanRestartAfterCancellationAndCancelIndependently() async throws {
        await start()
        await controller.cancelTranscription()
        let first = try await records()
        await start()
        let restarted = await controller.recording?.record.id
        XCTAssertNotNil(restarted)
        XCTAssertNotEqual(restarted, first.first?.id)
        await controller.cancelTranscription()
        let saved = try await records()
        XCTAssertEqual(saved.count, 2)
        XCTAssertEqual(effects.stops, 2)
        XCTAssertEqual(effects.destructions, 2)
        XCTAssertEqual(effects.transcriptions, 0)
        XCTAssertTrue(saved.allSatisfy { $0.failure == "Recording cancelled. Audio retained." && $0.result == nil })
        XCTAssertTrue(effects.outputs.isEmpty)
    }

    func testIdleCancellationDoesNotCreateHistoryOrStartCapture() async throws {
        await controller.cancelTranscription()
        let active = await controller.recording?.record.id
        let saved = try await records()
        XCTAssertNil(active)
        XCTAssertTrue(saved.isEmpty)
        XCTAssertEqual(effects.stops, 0)
        XCTAssertEqual(effects.destructions, 0)
        XCTAssertEqual(effects.transcriptions, 0)
        XCTAssertTrue(effects.outputs.isEmpty)
    }

    func testGuardedCancellationRefusesStaleRequestWithoutTouchingActiveCapture() async throws {
        await start()
        let original = await controller.recording?.record.id
        XCTAssertNotNil(original)
        await controller.cancelTranscription(ifCurrent: { false })
        let remaining = await controller.recording?.record.id
        XCTAssertEqual(remaining, original)
        XCTAssertEqual(effects.stops, 0)
        XCTAssertEqual(effects.destructions, 0)
        XCTAssertEqual(effects.transcriptions, 0)
        XCTAssertTrue(effects.outputs.isEmpty)
        await controller.cancelTranscription(ifCurrent: { true })
        let stopped = await controller.recording?.record.id
        XCTAssertNil(stopped)
        XCTAssertEqual(effects.stops, 1)
        XCTAssertEqual(effects.destructions, 1)
    }

    func testGuardedCancellationAfterRestartPreservesNewCapture() async throws {
        await start()
        let first = await controller.recording?.record.id
        await controller.cancelTranscription()
        await start()
        let second = await controller.recording?.record.id
        XCTAssertNotNil(second)
        XCTAssertNotEqual(second, first)
        await controller.cancelTranscription(ifCurrent: { false })
        let remaining = await controller.recording?.record.id
        XCTAssertEqual(remaining, second)
        XCTAssertEqual(effects.stops, 1)
        XCTAssertEqual(effects.destructions, 1)
        await controller.cancelTranscription(ifCurrent: { true })
        let stopped = await controller.recording?.record.id
        XCTAssertNil(stopped)
        XCTAssertEqual(effects.stops, 2)
        XCTAssertEqual(effects.destructions, 2)
        XCTAssertEqual(effects.transcriptions, 0)
        XCTAssertTrue(effects.outputs.isEmpty)
    }

    func testDisabledEscapePreservesCaptureButExplicitCancelStillRetainsAudio() async throws {
        try await setEscapeCancellation(false)
        await start()
        let original = await controller.recording?.record.id
        XCTAssertNotNil(original)
        await controller.cancelTranscription(fromEscape: true, ifCurrent: { true })
        let remaining = await controller.recording?.record.id
        XCTAssertEqual(remaining, original)
        XCTAssertEqual(effects.stops, 0)
        XCTAssertEqual(effects.destructions, 0)
        await controller.cancelTranscription()
        let saved = try await records()
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.failure, "Recording cancelled. Audio retained.")
        XCTAssertEqual(effects.stops, 1)
        XCTAssertEqual(effects.transcriptions, 0)
        XCTAssertTrue(effects.outputs.isEmpty)
    }

    func testDefaultAndExplicitEnabledEscapeCancelWithoutTranscription() async throws {
        for explicit in [false, true] {
            if explicit { try await setEscapeCancellation(true) }
            await start()
            let active = await controller.recording?.record.id
            XCTAssertNotNil(active)
            await controller.cancelTranscription(fromEscape: true)
            let remaining = await controller.recording?.record.id
            XCTAssertNil(remaining)
        }
        XCTAssertEqual(effects.stops, 2)
        XCTAssertEqual(effects.destructions, 2)
        XCTAssertEqual(effects.transcriptions, 0)
        XCTAssertTrue(effects.outputs.isEmpty)
    }

    func testDisabledEscapeSurvivesRestartAndStaleEnabledEscapeCannotCancelNewRun() async throws {
        try await setEscapeCancellation(false)
        await controller.close()
        controller = try DesktopHostController<FakePlatform>(directory: directory, effects: effects)
        await controller.markReadyForSelfTest()
        await start()
        let original = await controller.recording?.record.id
        XCTAssertNotNil(original)
        await controller.cancelTranscription(fromEscape: true)
        let remaining = await controller.recording?.record.id
        XCTAssertEqual(remaining, original)
        XCTAssertEqual(effects.stops, 0)
        await controller.cancelTranscription()
        try await setEscapeCancellation(true)
        await start()
        let restarted = await controller.recording?.record.id
        XCTAssertNotNil(restarted)
        XCTAssertNotEqual(restarted, original)
        await controller.cancelTranscription(fromEscape: true, ifCurrent: { false })
        let guarded = await controller.recording?.record.id
        XCTAssertEqual(guarded, restarted)
        XCTAssertEqual(effects.stops, 1)
        await controller.cancelTranscription(fromEscape: true, ifCurrent: { true })
        let stopped = await controller.recording?.record.id
        XCTAssertNil(stopped)
        XCTAssertEqual(effects.stops, 2)
    }

    private func setEscapeCancellation(_ enabled: Bool) async throws {
        let file = directory.appendingPathComponent("escape-preferences.json")
        let preferences = try DesktopConfiguration(values: [
            ApplicationPreferenceKey.cancelRecordingOnEscape.rawValue: AnyCodable(.bool(enabled))
        ])
        try JSONEncoder().encode(DesktopConfigurationDocument(preferences: preferences)).write(to: file)
        try await controller.importConfiguration(path: file.path)
    }
}

private final class RecordingCancelEffects: DesktopHostEffects, @unchecked Sendable {
    typealias Platform = FakePlatform
    private let base = SyntheticEffects()
    private let lock = NSLock()
    private var stopped = 0
    private var destroyed = 0
    private var transcribed = 0
    var stops: Int { lock.withLock { stopped } }
    var destructions: Int { lock.withLock { destroyed } }
    var transcriptions: Int { lock.withLock { transcribed } }
    var outputs: [(FakeJob, String)] { base.outputs }

    func apiKey(name: String) throws -> String { try base.apiKey(name: name) }
    func makeCapture(
        context: DesktopCaptureContext, deviceID: String, sampleRate: Int, frameMilliseconds: Int
    ) throws -> any DesktopRecordingCapture {
        Capture(
            context: context,
            onStop: { self.lock.withLock { self.stopped += 1 } },
            onDestroy: { self.lock.withLock { self.destroyed += 1 } }
        )
    }
    func makeLiveClient(
        model: String, key: String, language: String?, azureEndpoint: String
    ) -> (any FinalizingStreamingTranscriptionClient)? {
        base.makeLiveClient(model: model, key: key, language: language, azureEndpoint: azureEndpoint)
    }
    func transcribe(
        _ request: DesktopHostTranscriptionRequest, with controller: DesktopHostController<FakePlatform>
    ) async throws -> TranscriptionResult {
        lock.withLock { transcribed += 1 }
        return try await base.transcribe(request, with: controller)
    }
    func perform(_ job: FakeJob, text: String) -> DesktopTextOutputResult { base.perform(job, text: text) }
    func writeSettings(_ data: Data, to url: URL) throws { try base.writeSettings(data, to: url) }

    private final class Capture: DesktopRecordingCapture {
        let base: SyntheticCapture
        let onStop: () -> Void
        let onDestroy: () -> Void
        init(context: DesktopCaptureContext, onStop: @escaping () -> Void, onDestroy: @escaping () -> Void) {
            self.base = SyntheticCapture(context: context)
            self.onStop = onStop
            self.onDestroy = onDestroy
        }
        func start() throws { try base.start() }
        func stop() throws {
            try base.stop()
            onStop()
        }
        func destroy() {
            base.destroy()
            onDestroy()
        }
    }
}
