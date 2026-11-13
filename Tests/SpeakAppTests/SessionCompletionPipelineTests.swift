import Foundation
import SpeakCore
import XCTest

@testable import SpeakApp

@MainActor
final class SessionCompletionPipelineTests: XCTestCase {
    private final class FakeHost: SessionCompletionHost {
        var activeSession: ActiveSession?
        var published: [MainManager.State] = []
        var missingKeys: [(phase: HistoryError.Phase, message: String)] = []
        var releases = 0

        func sessionProcessingShouldContinue(_ session: ActiveSession) -> Bool { activeSession === session }
        func failForMissingAPIKey(_ session: ActiveSession, phase: HistoryError.Phase, message: String) async {
            missingKeys.append((phase, message))
            activeSession = nil
        }
        func attachFailureDiagnostics(to session: ActiveSession) {}
        func publish(_ state: MainManager.State) { published.append(state) }
        func publishFailure(_ message: String) { published.append(.failed(message)) }
        func offerPostProcessingRetry(for session: ActiveSession) -> Bool { false }
        func recordDeliveryFailure(
            _ error: Error, headline: String, remedy: DeliverySettingsRemedy?, finalText: String,
            session: ActiveSession
        ) async {}
        func recordInsertion(of text: String, range: VoiceEditTextRange?, target: TextOutputTarget?) {}
        func offerDeliveryRemedy(_ remedy: DeliverySettingsRemedy?) {}
        func captureFirstTranscriptionSucceededIfNeeded(session: ActiveSession) {}
        func releaseActiveSession() {
            releases += 1
            activeSession = nil
        }
    }

    private func makePipeline(
        _ env: AppEnvironment,
        host: FakeHost,
        transcription: TranscriptionManager? = nil,
        text: SessionTextServices? = nil
    ) -> SessionCompletionPipeline {
        let pipeline = SessionCompletionPipeline(
            settings: env.settings,
            permissions: env.permissions,
            transcription: transcription ?? env.transcription,
            text: text ?? env.main.text,
            history: env.history,
            hud: env.hud
        )
        pipeline.host = host
        return pipeline
    }

    private let summary = RecordingSummary(
        id: UUID(),
        url: URL(fileURLWithPath: "/dev/null/recording.m4a"),
        startedAt: Date(),
        duration: 1,
        fileSize: 0
    )

    func testBatchWithoutAKey_reportsTheMissingKeyAndDeliversNothing() async throws {
        let env = WireUp.bootstrap(options: makeWireUpTestOptions())
        env.settings.transcriptionMode = .batchRemote
        let hasKey = await env.transcription.hasValidBatchAPIKey()
        try XCTSkipIf(hasKey, "The test environment must have no batch API key")
        let host = FakeHost()
        let session = ActiveSession(gesture: .uiButton, hotKeyDescription: "Test")
        host.activeSession = session

        try await makePipeline(env, host: host).complete(session, recording: summary, isStreaming: false)

        XCTAssertEqual(host.missingKeys.map(\.phase), [.transcription])
        XCTAssertEqual(host.missingKeys.first?.message, SessionCompletionPipeline.missingBatchKeyMessage)
        XCTAssertTrue(host.published.isEmpty, "Nothing is delivered for a session without a key")
        XCTAssertEqual(host.releases, 0, "The missing-key path is the only release")
    }

    func testLiveStopFailure_reachesTheCallerWithoutDelivering() async {
        let env = WireUp.bootstrap(options: makeWireUpTestOptions())
        let host = FakeHost()
        let session = ActiveSession(gesture: .uiButton, hotKeyDescription: "Test")
        host.activeSession = session

        do {
            try await makePipeline(env, host: host).complete(session, recording: summary, isStreaming: true)
            XCTFail("Stopping a live session that never ran must throw")
        } catch {
            XCTAssertTrue(host.published.isEmpty)
            XCTAssertTrue(host.activeSession === session, "endSession's failure cleanup owns the session")
        }
    }

    /// A replacement session arrives while post-processing for the first is
    /// suspended. The first session's late streamed text, diagnostics and
    /// final result must not reach the replacement's HUD, session or History,
    /// and only the replacement's own hand-over retires the first session.
    func testReplacementDuringStreamedPostProcessing_lateResultsTouchNothingAndRetireOnce() async throws {
        let env = WireUp.bootstrap(options: makeWireUpTestOptions())
        env.settings.speedMode = .instant
        env.settings.postProcessingEnabled = true
        env.settings.postProcessingStreamingEnabled = true
        let model = ModelCatalog.resolvedPostProcessingModel(env.settings.postProcessingModel)
        XCTAssertFalse(PostProcessingManager.isLocalPostProcessingModel(model), "The test needs the remote path")

        let transcription = try await Self.runningLiveTranscription(env)
        let llm = GatedStreamingLLM()
        let text = Self.textServices(env, postProcessingClient: llm)
        let host = FakeHost()
        let first = ActiveSession(gesture: .uiButton, hotKeyDescription: "Test")
        host.activeSession = first
        let historyBefore = env.history.items.count
        let requested = expectation(description: "post-processing streams")
        llm.onRequest = { requested.fulfill() }
        let pipeline = makePipeline(env, host: host, transcription: transcription, text: text)

        let completion = Task { try await pipeline.complete(first, recording: summary, isStreaming: true) }
        await fulfillment(of: [requested], timeout: 5)
        llm.yield("Partial ")
        await Self.drainMainActor()
        XCTAssertEqual(env.hud.snapshot.streamingText, "Partial ", "The active session's stream reaches the HUD")

        host.releaseActiveSession()
        let replacement = ActiveSession(gesture: .uiButton, hotKeyDescription: "Test")
        host.activeSession = replacement
        env.hud.beginRecording()
        env.hud.updateStreamingText("")
        let replacementHUD = env.hud.snapshot

        llm.yield("late words from the first session")
        llm.finish()
        try await completion.value
        await Self.drainMainActor()

        XCTAssertEqual(env.hud.snapshot, replacementHUD, "Late streamed text must not reach the replacement's HUD")
        XCTAssertTrue(host.activeSession === replacement)
        XCTAssertNil(replacement.transcriptionResult)
        XCTAssertNil(replacement.postProcessingStarted)
        XCTAssertNil(replacement.diagnosticContext)
        XCTAssertTrue(replacement.events.isEmpty)
        XCTAssertTrue(host.published.isEmpty, "The retired session publishes no state")
        XCTAssertEqual(env.history.items.count, historyBefore, "The retired session writes no History")
        XCTAssertEqual(host.releases, 1, "Only the replacement's hand-over retires the first session")
    }

    /// A transcription manager whose live session is running and finishes with
    /// a transcript as soon as it is stopped.
    private static func runningLiveTranscription(_ env: AppEnvironment) async throws -> TranscriptionManager {
        let controller = FinishingLiveController(text: "first session words")
        let transcription = TranscriptionManager(
            appSettings: env.settings, permissionsManager: env.permissions,
            audioDeviceManager: AudioInputDeviceManager(appSettings: env.settings),
            batchClient: RemoteAudioTranscriber(client: env.openRouter), openRouter: env.openRouter,
            secureStorage: env.secureStorage, controllerOverride: { _ in controller }
        )
        try await transcription.startLiveTranscription()
        return transcription
    }

    /// The app's text services, post-processing through `client`.
    private static func textServices(_ env: AppEnvironment, postProcessingClient client: ChatLLMClient)
        -> SessionTextServices {
        let base = env.main.text
        return SessionTextServices(
            textProcessor: base.textProcessor, personalLexicon: base.personalLexicon,
            postProcessing: PostProcessingManager(
                client: client, settings: env.settings, personalLexicon: base.personalLexicon
            ),
            livePolish: base.livePolish, liveTextInserter: base.liveTextInserter,
            autoCorrectionTracker: base.autoCorrectionTracker
        )
    }

    /// Lets main-actor work enqueued by provider callbacks run.
    private static func drainMainActor() async {
        for _ in 0..<20 { await Task.yield() }
    }
}

/// Starts immediately and finishes with `text` when stopped.
@MainActor
private final class FinishingLiveController: LiveTranscriptionController {
    weak var delegate: LiveTranscriptionSessionDelegate?
    private(set) var isRunning = false
    private let text: String

    init(text: String) {
        self.text = text
    }

    func configure(language: String?, model: String) {}
    func start() async throws { isRunning = true }
    func stop() async {
        guard isRunning else { return }
        isRunning = false
        delegate?.liveTranscriber(self, didFinishWith: TranscriptionResult(
            text: text, segments: [], confidence: nil, duration: 1,
            modelIdentifier: "elevenlabs/scribe-v2-streaming", cost: nil, rawPayload: nil, debugInfo: nil
        ))
    }
}

/// A streaming cleanup model the test feeds chunk by chunk.
private final class GatedStreamingLLM: StreamingChatLLMClient, @unchecked Sendable {
    var onRequest: (() -> Void)?
    private var continuation: AsyncThrowingStream<String, Error>.Continuation?

    func sendChat(
        systemPrompt: String?, messages: [ChatMessage], model: String, temperature: Double
    ) async throws -> ChatResponse {
        throw URLError(.badServerResponse)
    }

    func sendChatStreaming(
        systemPrompt: String?, messages: [ChatMessage], model: String, temperature: Double
    ) -> AsyncThrowingStream<String, Error> {
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        self.continuation = continuation
        onRequest?()
        return stream
    }

    func yield(_ chunk: String) { continuation?.yield(chunk) }
    func finish() { continuation?.finish() }
}
