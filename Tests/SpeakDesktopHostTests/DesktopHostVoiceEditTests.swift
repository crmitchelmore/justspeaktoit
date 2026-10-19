import Foundation
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost
import XCTest

final class DesktopHostVoiceEditTests: XCTestCase {
    private var directory: URL!
    private var controller: DesktopHostController<FakePlatform>!
    private var effects: VoiceEditFixtureEffects!

    override func setUp() async throws {
        FakeLog.shared.reset()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("voice-edit-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        effects = VoiceEditFixtureEffects()
        controller = try DesktopHostController<FakePlatform>(directory: directory, effects: effects)
        await controller.markReadyForSelfTest()
        let index = try XCTUnwrap(DesktopHostModels.all.firstIndex { $0.id == "openai/whisper-1" })
        let selected = await controller.selectModel(index)
        XCTAssertTrue(selected)
        FakeLog.shared.setKey("fixture-transcription-key", name: "openai.apiKey")
        FakeLog.shared.setKey("fixture-rewrite-key", name: "openrouter.apiKey")
        await controller.savePostProcessing(enabled: false, modelIndex: 0, prompt: "Not an editing prompt.", key: "")
        FakeLog.shared.setKey("fixture-rewrite-key", name: "openrouter.apiKey")
    }

    override func tearDown() async throws {
        await effects.replyGate.release()
        await controller.close()
        try? FileManager.default.removeItem(at: directory)
    }

    func testMissingRewriteKeyAndEmptySelection_NeverOpenTheMicrophone() async throws {
        FakeLog.shared.setKey("", name: "openrouter.apiKey")
        await controller.toggleVoiceEdit(source: VoiceEditFixtureSelection().source(), deviceID: "")
        await idle()
        XCTAssertEqual(effects.lifecycle, [0, 0, 0])
        XCTAssertTrue(FakeLog.shared.allStatuses.contains { $0.contains("OpenRouter key") })
        FakeLog.shared.setKey("fixture-rewrite-key", name: "openrouter.apiKey")
        await controller.toggleVoiceEdit(source: VoiceEditFixtureSelection(text: "").source(), deviceID: "")
        await idle()
        XCTAssertEqual(effects.lifecycle, [0, 0, 0])
        XCTAssertTrue(effects.rewrites.isEmpty)
    }

    func testBatchEdit_UsesRawInstructionAndPrivateAudioWithoutHistoryOrOrdinaryCleanup() async throws {
        let before = try regularFiles()
        let selection = VoiceEditFixtureSelection()
        await controller.toggleVoiceEdit(source: selection.source(), deviceID: "")
        await listening()
        FakeLog.shared.setKey("newer-transcription-key", name: "openai.apiKey")
        FakeLog.shared.setKey("newer-rewrite-key", name: "openrouter.apiKey")
        await controller.toggleVoiceEdit(source: VoiceEditFixtureSelection().source(), deviceID: "")
        await idle()
        await controller.voiceEditWorkersEnded()
        XCTAssertEqual(selection.replacements, ["Edited selection."])
        XCTAssertEqual(effects.lifecycle, [1, 1, 1])
        XCTAssertEqual(effects.rewrites.count, 1)
        XCTAssertEqual(effects.rewrites.first?.selection, "Original selection.")
        XCTAssertEqual(effects.rewrites.first?.instruction, "stop recording; make this shorter")
        XCTAssertEqual(effects.rewriteKeys, ["fixture-rewrite-key"])
        XCTAssertEqual(effects.requests.count, 1)
        XCTAssertEqual(effects.requests.first?.historySaved, false)
        XCTAssertEqual(effects.requests.first?.key, "fixture-transcription-key")
        XCTAssertTrue(effects.requests.first?.audio.path.contains("VoiceEdit") == true)
        XCTAssertEqual(try regularFiles(), before)
    }

    func testNormalDictationCannotStealVoiceEditingAndCancelStopsCaptureOnce() async {
        let selection = VoiceEditFixtureSelection()
        await controller.toggleVoiceEdit(source: selection.source(), deviceID: "")
        await listening()
        let index = await controller.selectedIndex()
        await controller.toggle(
            target: "other field", modelIndex: index, deviceID: "", targetExecutablePath: nil,
            textOutput: FakeTextOutput(label: "insert")
        )
        let stillListening = await controller.voiceEditIsListening
        XCTAssertTrue(stillListening)
        await controller.cancelVoiceEdit()
        await controller.cancelVoiceEdit()
        await idle()
        await controller.voiceEditWorkersEnded()
        XCTAssertEqual(effects.lifecycle, [1, 1, 1])
        XCTAssertTrue(selection.replacements.isEmpty)
        XCTAssertTrue(effects.rewrites.isEmpty)
    }

    func testLiveInstruction_UsesAuthoritativeFinalTextWithoutBatchTranscriptionOrHistory() async throws {
        DesktopHostModels.configure(streamingQualified: true)
        let index = try XCTUnwrap(DesktopHostModels.all.firstIndex {
            $0.id == AssemblyAIModels.universal36ProStreamingID
        })
        let selected = await controller.selectModel(index)
        XCTAssertTrue(selected)
        FakeLog.shared.setKey("fixture-live-key", name: "assemblyai.apiKey")
        let client = AutoCleanStreamingClient()
        client.finalText = "  make this lowercase \n"
        effects.liveClient = client
        let before = try regularFiles()
        let selection = VoiceEditFixtureSelection()
        await controller.toggleVoiceEdit(source: selection.source(), deviceID: "")
        await listening()
        client.emit("interim instruction that must not be used")
        await controller.toggleVoiceEdit(source: VoiceEditFixtureSelection().source(), deviceID: "")
        await idle()
        await controller.voiceEditWorkersEnded()
        XCTAssertEqual(effects.rewrites.first?.instruction, "make this lowercase")
        XCTAssertTrue(effects.requests.isEmpty)
        XCTAssertEqual(selection.replacements, ["Edited selection."])
        XCTAssertEqual(effects.lifecycle, [1, 1, 1])
        XCTAssertEqual(try regularFiles(), before)
    }

    func testCloseWhileListening_StopsPrivateCaptureWithoutRewritingOrReplacing() async {
        let selection = VoiceEditFixtureSelection()
        await controller.toggleVoiceEdit(source: selection.source(), deviceID: "")
        await listening()
        let report = await controller.close()
        XCTAssertEqual(report.unfinishedOperations, 0)
        XCTAssertEqual(effects.lifecycle, [1, 1, 1])
        XCTAssertTrue(effects.rewrites.isEmpty)
        XCTAssertTrue(selection.replacements.isEmpty)
        await controller.toggleVoiceEdit(source: selection.source(), deviceID: "")
        XCTAssertEqual(effects.lifecycle, [1, 1, 1])
    }

    func testCaptureStartFailureAndStopFailure_AreReportedAndDestroyOnlyOnce() async {
        effects.failStart = true
        await controller.toggleVoiceEdit(source: VoiceEditFixtureSelection().source(), deviceID: "")
        await idle()
        await controller.voiceEditWorkersEnded()
        XCTAssertEqual(effects.lifecycle, [1, 1, 1])
        XCTAssertTrue(FakeLog.shared.allStatuses.contains { $0.contains("fixture capture start") })
        effects.failStart = false
        effects.failStop = true
        await controller.toggleVoiceEdit(source: VoiceEditFixtureSelection().source(), deviceID: "")
        await listening()
        await controller.toggleVoiceEdit(source: VoiceEditFixtureSelection().source(), deviceID: "")
        await idle()
        await controller.voiceEditWorkersEnded()
        XCTAssertEqual(effects.lifecycle, [2, 2, 2])
        XCTAssertTrue(effects.rewrites.isEmpty)
        XCTAssertTrue(FakeLog.shared.allStatuses.contains { $0.contains("fixture capture stop") })
    }

    func testUncooperativeRewrite_DoesNotBlockCancelRestartOrWriteLate() async {
        let entered = expectation(description: "rewrite entered")
        effects.beforeRewrite = { entered.fulfill() }
        await effects.replyGate.hold()
        let old = VoiceEditFixtureSelection()
        await controller.toggleVoiceEdit(source: old.source(), deviceID: "")
        await listening()
        await controller.toggleVoiceEdit(source: VoiceEditFixtureSelection().source(), deviceID: "")
        await fulfillment(of: [entered], timeout: 2)
        await controller.cancelVoiceEdit()
        await idle()
        let newer = VoiceEditFixtureSelection()
        await controller.toggleVoiceEdit(source: newer.source(), deviceID: "")
        await listening()
        await controller.cancelVoiceEdit()
        await idle()
        await effects.replyGate.release()
        await controller.voiceEditWorkersEnded()
        XCTAssertTrue(old.replacements.isEmpty)
        XCTAssertTrue(newer.replacements.isEmpty)
        XCTAssertEqual(effects.lifecycle, [2, 2, 2])
    }

    private func listening() async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            if await controller.voiceEditIsListening { return }
            await Task.yield()
        }
        XCTFail("The synthetic voice-edit capture did not reach listening.")
    }

    private func idle() async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            if await controller.canUseHistory { return }
            await Task.yield()
        }
        XCTFail("Voice-edit admission did not release the host.")
    }

    private func regularFiles() throws -> [String: Data] {
        var files: [String: Data] = [:]
        for path in try FileManager.default.subpathsOfDirectory(atPath: directory.path) {
            let url = directory.appendingPathComponent(path)
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                files[path] = try Data(contentsOf: url)
            }
        }
        return files
    }
}

private final class VoiceEditFixtureSelection: @unchecked Sendable {
    private let lock = NSLock()
    private let text: String
    private var written: [String] = []
    var replacements: [String] { lock.withLock { written } }
    init(text: String = "Original selection.") { self.text = text }
    func source() -> DesktopHostVoiceEditSource {
        .init(
            executablePath: nil, capture: { self.text },
            replace: { text in
                self.lock.withLock { self.written.append(text) }
                return "Fixture selection replaced."
            },
            cancel: {}
        )
    }
}

private actor VoiceEditFixtureReplyGate {
    private var open = true
    private var pending: [CheckedContinuation<Void, Never>] = []
    func hold() { open = false }
    func wait() async {
        if !open { await withCheckedContinuation { pending.append($0) } }
    }
    func release() {
        open = true
        let waiters = pending
        pending = []
        waiters.forEach { $0.resume() }
    }
}

private final class VoiceEditFixtureEffects: DesktopHostEffects, @unchecked Sendable {
    typealias Platform = FakePlatform
    let replyGate = VoiceEditFixtureReplyGate()
    private let lock = NSLock()
    private var counts = [0, 0, 0]
    private var recordedRewrites: [DesktopVoiceEdit.Request] = []
    private var recordedKeys: [String] = []
    private var recordedRequests: [DesktopHostTranscriptionRequest] = []
    var failStart = false
    var failStop = false
    var beforeRewrite: (@Sendable () -> Void)?
    var liveClient: AutoCleanStreamingClient?
    var lifecycle: [Int] { lock.withLock { counts } }
    var rewrites: [DesktopVoiceEdit.Request] { lock.withLock { recordedRewrites } }
    var rewriteKeys: [String] { lock.withLock { recordedKeys } }
    var requests: [DesktopHostTranscriptionRequest] { lock.withLock { recordedRequests } }
    func count(_ index: Int) { lock.withLock { counts[index] += 1 } }
    func apiKey(name: String) throws -> String { FakeLog.shared.key(name) }
    func makeCapture(
        context: DesktopCaptureContext, deviceID: String, sampleRate: Int, frameMilliseconds: Int
    ) throws -> any DesktopRecordingCapture {
        VoiceEditFixtureCapture(context: context, effects: self, failStart: failStart, failStop: failStop)
    }
    func makeLiveClient(
        model: String, key: String, language: String?, azureEndpoint: String
    ) -> (any FinalizingStreamingTranscriptionClient)? { liveClient }
    func transcribe(
        _ request: DesktopHostTranscriptionRequest, with controller: DesktopHostController<FakePlatform>
    ) async throws -> TranscriptionResult {
        throw DesktopHostError(message: "Voice editing must not use the ordinary History transcription path.")
    }
    func transcribeComparison(
        _ request: DesktopHostTranscriptionRequest, azureEndpoint: String,
        with controller: DesktopHostController<FakePlatform>
    ) async throws -> TranscriptionResult {
        lock.withLock { recordedRequests.append(request) }
        return .init(
            text: "  stop recording; make this shorter \n", segments: [], confidence: nil, duration: request.duration,
            modelIdentifier: request.model, cost: nil, rawPayload: nil, debugInfo: nil
        )
    }
    func rewriteSelection(_ request: DesktopVoiceEdit.Request, key: String) async throws -> String {
        lock.withLock { recordedRewrites.append(request); recordedKeys.append(key) }
        beforeRewrite?()
        await replyGate.wait()
        return "Edited selection."
    }
    func postProcess(
        text: String, options: DesktopPostProcessing.Options, key: String, directives: [String], tags: [String]
    ) async throws -> DesktopPostProcessing.Outcome {
        throw DesktopHostError(message: "Voice editing must bypass ordinary cleanup.")
    }
    func polishLive(
        text: String, model: String, key: String, localLLM: (any DesktopLocalLLMEngine)?
    ) async throws -> String {
        throw DesktopHostError(message: "Voice editing must bypass Auto-Clean.")
    }
    func perform(_ job: FakeJob, text: String) -> DesktopTextOutputResult {
        XCTFail("Voice editing must not use automatic dictation output.")
        return .init(.failed, status: "Unexpected ordinary output.")
    }
    func writeSettings(_ data: Data, to url: URL) throws { try data.write(to: url, options: .atomic) }
}

private final class VoiceEditFixtureCapture: DesktopRecordingCapture {
    private let context: DesktopCaptureContext
    private let effects: VoiceEditFixtureEffects
    private let failStart: Bool
    private let failStop: Bool
    init(context: DesktopCaptureContext, effects: VoiceEditFixtureEffects, failStart: Bool, failStop: Bool) {
        self.context = context
        self.effects = effects
        self.failStart = failStart
        self.failStop = failStop
    }
    func start() throws {
        effects.count(0)
        if failStart { throw DesktopHostError(message: "fixture capture start") }
        let samples = [Int16](repeating: 1_000, count: 1_600)
        samples.withUnsafeBufferPointer { context.receive($0.baseAddress!, count: $0.count) }
    }
    func stop() throws {
        effects.count(1)
        if failStop { throw DesktopHostError(message: "fixture capture stop") }
    }
    func destroy() { effects.count(2) }
}
