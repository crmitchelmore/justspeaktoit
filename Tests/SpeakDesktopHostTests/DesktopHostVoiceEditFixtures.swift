import Foundation
import XCTest
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost

final class VoiceEditFixtureSelection: @unchecked Sendable {
    private let lock = NSLock()
    private let text: String
    private let recovery: Bool
    private var written: [String] = []
    var replacements: [String] { lock.withLock { written } }
    init(text: String = "Original selection.", recovery: Bool = false) {
        self.text = text
        self.recovery = recovery
    }
    func source() -> DesktopHostVoiceEditSource {
        .init(
            executablePath: nil, capture: { self.text },
            replace: { text in
                if self.recovery { return .recovery("Rewrite copied for manual paste; the anchor changed.") }
                self.lock.withLock { self.written.append(text) }
                return .replaced("Fixture selection replaced.")
            },
            cancel: {}
        )
    }
}

actor VoiceEditFixtureReplyGate {
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

final class VoiceEditFixtureEffects: DesktopHostEffects, @unchecked Sendable {
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
