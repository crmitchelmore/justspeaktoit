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

    private func makePipeline(_ env: AppEnvironment, host: FakeHost) -> SessionCompletionPipeline {
        let pipeline = SessionCompletionPipeline(
            settings: env.settings,
            permissions: env.permissions,
            transcription: env.transcription,
            text: env.main.text,
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
}
