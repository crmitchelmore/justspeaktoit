import Foundation
import XCTest
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost

private final class ClipboardFinalClient: FinalizingStreamingTranscriptionClient, @unchecked Sendable {
    let finalShape = TranscriptFinalShape.standaloneSegments
    let finalisationBudget: TimeInterval? = nil
    private let lock = NSLock()
    private var transcript: ((String, Bool) -> Void)?
    private var failure: ((Error) -> Void)?
    func start(onTranscript: @escaping (String, Bool) -> Void, onError: @escaping (Error) -> Void) {
        lock.withLock { transcript = onTranscript; failure = onError }
    }
    func emit(_ text: String) { lock.withLock { transcript }?(text, false) }
    func fail() { lock.withLock { failure }?(DesktopHostError(message: "Synthetic provider failure.")) }
    func sendAudio(_ audioData: Data) {}
    func stop() {}
    func cancel() {}
    func finishAndWait() async -> String? { "copy pasta" }
}

private final class ClipboardHostEffects: DesktopHostEffects, @unchecked Sendable {
    typealias Platform = FakePlatform
    let base = SyntheticEffects()
    let live = ClipboardFinalClient()
    let readGate = Gate(open: true)
    let enteredRead = Gate(open: false)
    private let lock = NSLock()
    private var reads = 0
    private var requests: [DesktopHostTranscriptionRequest] = []
    var text = "copy pasta"
    var clipboard: String? = "Synthetic clipboard"
    var readFailure: DesktopClipboardReadError?
    var readCount: Int { lock.withLock { reads } }
    var transcriptions: [DesktopHostTranscriptionRequest] { lock.withLock { requests } }
    func apiKey(name: String) throws -> String { try base.apiKey(name: name) }
    func makeCapture(
        context: DesktopCaptureContext, deviceID: String, sampleRate: Int, frameMilliseconds: Int
    ) throws -> any DesktopRecordingCapture {
        try base.makeCapture(
            context: context, deviceID: deviceID, sampleRate: sampleRate, frameMilliseconds: frameMilliseconds
        )
    }
    func makeLiveClient(
        model: String, key: String, language: String?, azureEndpoint: String
    ) -> (any FinalizingStreamingTranscriptionClient)? { live }
    func transcribe(
        _ request: DesktopHostTranscriptionRequest, with controller: DesktopHostController<FakePlatform>
    ) async throws -> TranscriptionResult {
        lock.withLock { requests.append(request) }
        await base.transcription.pass()
        try Task.checkCancellation()
        return TranscriptionResult(
            text: text, segments: [], confidence: nil, duration: request.duration,
            modelIdentifier: request.model, cost: nil, rawPayload: nil, debugInfo: nil
        )
    }
    func readClipboardText() async throws -> String? {
        lock.withLock { reads += 1 }
        enteredRead.release()
        await readGate.pass()
        // Intentionally return even after cancellation to exercise late-result fencing.
        if let readFailure { throw readFailure }
        return clipboard
    }
    func perform(_ job: FakeJob, text: String) -> DesktopTextOutputResult { base.perform(job, text: text) }
    func writeSettings(_ data: Data, to url: URL) throws { try base.writeSettings(data, to: url) }
}

final class DesktopHostClipboardCommandTests: XCTestCase {
    private var directory: URL!
    private var effects: ClipboardHostEffects!
    private var controller: DesktopHostController<FakePlatform>!
    private var batchIndex = 0

    override func setUp() async throws {
        FakeLog.shared.reset()
        DesktopHostModels.configure(streamingQualified: true)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-host-\(UUID())")
        effects = ClipboardHostEffects()
        controller = try DesktopHostController<FakePlatform>(directory: directory, effects: effects)
        await controller.markReadyForSelfTest()
        batchIndex = try XCTUnwrap(
            DesktopHostModels.all.firstIndex { DesktopTranscription.provider(for: $0.id) != nil }
        )
        for model in DesktopHostModels.all {
            if let provider = DesktopHostModels.provider(for: model.id) {
                FakeLog.shared.setKey("synthetic-key", name: provider.apiKeyIdentifier)
            }
        }
        try await configure()
    }

    override func tearDown() async throws {
        effects.readGate.release()
        effects.base.transcription.release()
        await controller.close()
        try? FileManager.default.removeItem(at: directory)
    }

    private func configure(enabled: Bool = true, triggers: String = "") async throws {
        let configuration = try DesktopConfiguration(values: [
            "postRecordingTailDuration": AnyCodable(.double(0)),
            "voiceCommandsEnabled": AnyCodable(.bool(enabled)),
            "clipboardInsertionTriggers": AnyCodable(.string(triggers))
        ])
        try await controller.saveConfiguration(configuration.entries)
    }

    private func toggle(index: Int? = nil) async {
        await controller.toggle(
            target: "synthetic-field", modelIndex: index ?? batchIndex, deviceID: "",
            targetExecutablePath: nil, textOutput: FakeTextOutput()
        )
    }

    private func saved() async throws -> DesktopRecordingStore.Record {
        let records = try await DesktopRecordingStore(directory: directory.appendingPathComponent("History")).records()
        return try XCTUnwrap(records.first)
    }

    private func waitForRead() async throws {
        for _ in 0..<1_000 {
            if effects.enteredRead.isOpen { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("The finalization clipboard read never started.")
        throw DesktopHostError(message: "Missing synthetic clipboard read.")
    }

    func testBatchFinalExpandsOnceAndPreservesProviderText() async throws {
        await toggle()
        await toggle()
        await controller.waitForClipboardOutputForTest()
        let record = try await saved()
        XCTAssertEqual(record.result?.text, "copy pasta")
        XCTAssertEqual(record.displayText, "Synthetic clipboard")
        XCTAssertEqual(effects.readCount, 1)
        XCTAssertEqual(effects.base.outputs.map(\.1), ["Synthetic clipboard"])
        XCTAssertNil(record.failure)
    }

    func testCustomPolicyIsFrozenBeforeCaptureNotReadFromChangedSettings() async throws {
        effects.text = "my snippet"
        try await configure(triggers: "my snippet")
        await toggle()
        let replacement = try DesktopConfiguration(values: [
            "voiceCommandsEnabled": AnyCodable(.bool(false)),
            "clipboardInsertionTriggers": AnyCodable(.string("different phrase")),
            "postRecordingTailDuration": AnyCodable(.double(0))
        ])
        await controller.replaceClipboardConfigurationForTest(replacement)
        await toggle()
        let record = try await saved()
        XCTAssertEqual(record.displayText, "Synthetic clipboard")
        XCTAssertEqual(effects.readCount, 1)
    }

    func testOrdinaryTextNeverReadsClipboard() async throws {
        effects.text = "Ordinary synthetic speech."
        await toggle()
        await toggle()
        XCTAssertEqual(effects.readCount, 0)
        let record = try await saved()
        XCTAssertEqual(record.displayText, effects.text)
    }

    func testDisabledPolicyNeverReadsClipboard() async throws {
        try await configure(enabled: false)
        await toggle()
        await toggle()
        XCTAssertEqual(effects.readCount, 0)
        let record = try await saved()
        XCTAssertEqual(record.displayText, "copy pasta")
    }

    func testAbsentClipboardPreservesCommand() async throws {
        effects.clipboard = nil
        await toggle()
        await toggle()
        let record = try await saved()
        XCTAssertEqual(record.displayText, "copy pasta")
        XCTAssertNil(record.failure)
        XCTAssertEqual(effects.readCount, 1)
    }

    func testUnsupportedReadRetainsRawTextAndPreventsDelivery() async throws {
        effects.readFailure = .unsupported("Synthetic Wayland clipboard read is unsupported.")
        await toggle()
        await toggle()
        await controller.waitForClipboardOutputForTest()
        let record = try await saved()
        XCTAssertEqual(record.result?.text, "copy pasta")
        XCTAssertTrue(record.failure?.contains("Synthetic Wayland") == true)
        XCTAssertTrue(effects.base.outputs.isEmpty)
        let audio = try await controller.store.audioURL(for: record)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
    }

    func testCancellationFencesLateClipboardResultAndRetainsRecovery() async throws {
        effects.readGate.hold()
        await toggle()
        let stopping = Task { await self.toggle() }
        try await waitForRead()
        await controller.cancelTranscription()
        effects.readGate.release()
        await stopping.value
        await controller.waitForClipboardOutputForTest()
        let record = try await saved()
        XCTAssertEqual(record.result?.text, "copy pasta")
        XCTAssertTrue(record.failure?.contains("Cancelled") == true)
        XCTAssertTrue(effects.base.outputs.isEmpty)
    }

    func testCloseFencesLateReadAndDoesNotPublishFurtherUI() async throws {
        effects.readGate.hold()
        await toggle()
        let stopping = Task { await self.toggle() }
        try await waitForRead()
        await controller.close()
        let statesAfterClose = FakeLog.shared.allStatuses
        effects.readGate.release()
        await stopping.value
        XCTAssertEqual(FakeLog.shared.allStatuses, statesAfterClose)
        XCTAssertTrue(effects.base.outputs.isEmpty)
        let record = try await saved()
        XCTAssertEqual(record.result?.text, "copy pasta")
    }

    func testLiveInterimReadsNothingAndHealthyFinalExpandsOnce() async throws {
        let index = try XCTUnwrap(DesktopHostModels.all.firstIndex {
            $0.id == AssemblyAIModels.universal36ProStreamingID
        })
        await toggle(index: index)
        effects.live.emit("copy pasta")
        effects.live.emit("")
        XCTAssertEqual(effects.readCount, 0)
        await toggle(index: index)
        await controller.waitForClipboardOutputForTest()
        let record = try await saved()
        XCTAssertEqual(record.result?.text, "copy pasta")
        XCTAssertEqual(record.displayText, "Synthetic clipboard")
        XCTAssertEqual(effects.readCount, 1)
        XCTAssertEqual(effects.base.outputs.map(\.1), ["Synthetic clipboard"])
    }

    func testFailedLiveProviderNeverReadsOrDeliversClipboard() async throws {
        let index = try XCTUnwrap(DesktopHostModels.all.firstIndex {
            $0.id == AssemblyAIModels.universal36ProStreamingID
        })
        await toggle(index: index)
        effects.live.emit("copy pasta")
        effects.live.fail()
        await toggle(index: index)
        let record = try await saved()
        XCTAssertNotNil(record.failure)
        XCTAssertEqual(effects.readCount, 0)
        XCTAssertTrue(effects.base.outputs.isEmpty)
    }
}

extension DesktopHostClipboardCommandTests {
    func testCommandsPrecedeCanonicalVocabularyWithoutRewritingRawText() async throws {
        _ = try await controller.vocabularyEvent(kind: 0, payload: DesktopVocabularyWire.encode([
            "save", "", "Synthetic", "Canonical", "Synthetic", "automatic", "", "high", ""
        ]))
        await toggle()
        await toggle()
        let record = try await saved()
        XCTAssertEqual(record.originalText, "copy pasta")
        XCTAssertEqual(record.correctedText, "Canonical clipboard")
        XCTAssertEqual(record.lexiconSummary?.applied.count, 1)
        XCTAssertEqual(effects.readCount, 1)
    }

    func testEmptyExpansionSkipsEvenConfiguredRemotePolishing() async throws {
        effects.clipboard = " \n\t"
        await controller.enableClipboardPolishingForTest()
        await toggle()
        await toggle()
        await controller.waitForClipboardOutputForTest()
        let record = try await saved()
        XCTAssertEqual(record.originalText, "copy pasta")
        XCTAssertEqual(record.processedText, "")
        XCTAssertNil(record.postProcessingFailure)
        XCTAssertTrue(effects.base.outputs.isEmpty)
    }

    func testImportAndRetryDoNotReinterpretCommandsAgainstTodaysClipboard() async throws {
        await toggle()
        await toggle()
        let original = try await saved()
        let audio = try await controller.store.audioURL(for: original)
        await controller.importAudio(path: audio.path, modelIndex: batchIndex)
        let imported = try await saved()
        XCTAssertEqual(imported.displayText, "copy pasta")
        XCTAssertEqual(effects.readCount, 1)
        await controller.retryHistory(original.id.uuidString)
        let retried = try await controller.store.record(id: original.id)
        XCTAssertEqual(retried.displayText, "copy pasta")
        XCTAssertEqual(effects.readCount, 1)
    }

    func testRecordedNilConfigurationKeepsCanonicalDefaultsAndFrozenEndpoint() async throws {
        await controller.replaceClipboardConfigurationForTest(nil, endpoint: "https://old.invalid")
        await toggle()
        let disabled = try DesktopConfiguration(values: ["voiceCommandsEnabled": AnyCodable(.bool(false))])
        await controller.replaceClipboardConfigurationForTest(disabled, endpoint: "https://changed.invalid")
        await toggle()
        let record = try await saved()
        XCTAssertEqual(record.displayText, "Synthetic clipboard")
        XCTAssertEqual(effects.readCount, 1)
        XCTAssertEqual(effects.transcriptions.first?.azureEndpoint, "https://old.invalid")
    }
}

private extension DesktopHostController where Platform == FakePlatform {
    func waitForClipboardOutputForTest() async {
        if let delivery = outputSlot.task { await delivery.value }
    }

    func replaceClipboardConfigurationForTest(_ configuration: DesktopConfiguration?, endpoint: String? = nil) {
        settings.configuration = configuration
        if let endpoint { settings.azureSpeechResourceEndpoint = endpoint }
    }

    func enableClipboardPolishingForTest() {
        var options = settings.postProcessing ?? .init()
        options.mode = .remote
        // Any regression must fail locally before an HTTP request can be made.
        options.modelIdentifier = "synthetic-unsupported-model"
        settings.postProcessing = options
    }
}
