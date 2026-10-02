import Foundation
import XCTest
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost

/// The model and microphone choices go through the host's settings writer,
/// are used only once saved, and write nothing when they did not change.
final class DesktopHostModelSelectionTests: XCTestCase {
    private var directory: URL!
    private var effects: SettingsWriteEffects!
    private var controller: DesktopHostController<FakePlatform>!
    private var batchIndex = 0
    private var otherBatchIndex = 0

    override func setUp() async throws {
        FakeLog.shared.reset()
        DesktopHostModels.configure(streamingQualified: false)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("host-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        effects = SettingsWriteEffects()
        controller = try DesktopHostController<FakePlatform>(directory: directory, effects: effects)
        await controller.markReadyForSelfTest()
        let batch = DesktopHostModels.all.indices.filter {
            DesktopTranscription.provider(for: DesktopHostModels.all[$0].id) != nil
        }
        batchIndex = try XCTUnwrap(batch.first)
        otherBatchIndex = try XCTUnwrap(batch.dropFirst().first)
        for index in [batchIndex, otherBatchIndex] {
            let model = DesktopHostModels.all[index].id
            let credential = try XCTUnwrap(DesktopHostModels.provider(for: model)).apiKeyIdentifier
            FakeLog.shared.setKey("synthetic-key", name: credential)
        }
    }

    override func tearDown() async throws {
        await controller.close()
        try? FileManager.default.removeItem(at: directory)
        DesktopHostModels.configure(streamingQualified: true)
    }

    func testAnUnchangedChoiceIsNotWrittenAgainWhenRecordingStarts() async throws {
        await controller.selectModel(batchIndex)
        await controller.selectMicrophone("usb-microphone")
        let written = effects.writes
        XCTAssertGreaterThan(written, 0, "the microphone choice did not go through the settings writer")

        await controller.toggle(
            target: nil, modelIndex: batchIndex, deviceID: "usb-microphone", targetExecutablePath: nil,
            textOutput: FakeTextOutput()
        )
        let active = await controller.recording
        XCTAssertNotNil(active)
        XCTAssertEqual(effects.writes, written, "an unchanged model or microphone was written again")
    }

    func testAChoiceThatCannotBeSavedIsNotUsed() async throws {
        await controller.selectModel(batchIndex)
        effects.refusesWrites = true

        let selected = await controller.selectModel(otherBatchIndex)
        XCTAssertFalse(selected)
        let index = await controller.selectedIndex()
        XCTAssertEqual(index, batchIndex, "a model that could not be saved is in use")
        XCTAssertEqual(FakeLog.shared.allStatuses.last?.hasPrefix("Could not save settings"), true)

        // Record with that model starts nothing and leaves the reason shown.
        await controller.toggle(
            target: nil, modelIndex: otherBatchIndex, deviceID: "", targetExecutablePath: nil,
            textOutput: FakeTextOutput()
        )
        let active = await controller.recording
        XCTAssertNil(active, "a recording started with a model that could not be saved")
        XCTAssertEqual(FakeLog.shared.allStatuses.last?.hasPrefix("Could not save settings"), true)

        await controller.selectMicrophone("usb-microphone")
        let microphone = await controller.selectedMicrophone()
        XCTAssertEqual(microphone, "", "a microphone that could not be saved is in use")

        effects.refusesWrites = false
        let saved = await controller.selectModel(otherBatchIndex)
        XCTAssertTrue(saved)
        let file = try JSONSerialization.jsonObject(
            with: Data(contentsOf: directory.appendingPathComponent("settings.json"))
        ) as? [String: Any]
        XCTAssertEqual(file?["model"] as? String, DesktopHostModels.all[otherBatchIndex].id)
    }
}

/// Counts settings writes and can refuse them, as a read-only profile or a
/// full disk would.
private final class SettingsWriteEffects: DesktopHostEffects, @unchecked Sendable {
    typealias Platform = FakePlatform
    private let lock = NSLock()
    private var count = 0
    private var refusing = false

    var writes: Int { lock.withLock { count } }
    var refusesWrites: Bool {
        get { lock.withLock { refusing } }
        set { lock.withLock { refusing = newValue } }
    }

    func apiKey(name: String) throws -> String { FakeLog.shared.key(name) }
    func makeCapture(
        context: DesktopCaptureContext, deviceID: String, sampleRate: Int, frameMilliseconds: Int
    ) throws -> any DesktopRecordingCapture { SyntheticCapture(context: context) }
    func makeLiveClient(
        model: String, key: String, language: String?, azureEndpoint: String
    ) -> (any FinalizingStreamingTranscriptionClient)? { nil }
    func transcribe(
        _ request: DesktopHostTranscriptionRequest, with controller: DesktopHostController<FakePlatform>
    ) async throws -> TranscriptionResult {
        TranscriptionResult(
            text: "Synthetic transcript", segments: [], confidence: nil, duration: request.duration,
            modelIdentifier: request.model, cost: nil, rawPayload: nil, debugInfo: nil
        )
    }
    func perform(_ job: FakeJob, text: String) -> String { "Delivered." }
    func writeSettings(_ data: Data, to url: URL) throws {
        try lock.withLock {
            if refusing { throw CocoaError(.fileWriteOutOfSpace) }
            count += 1
        }
        try data.write(to: url, options: .atomic)
    }
}
