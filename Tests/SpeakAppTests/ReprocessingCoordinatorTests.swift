import Foundation
import SpeakCore
import XCTest

@testable import SpeakApp

@MainActor
final class ConnectionPrewarmerTests: XCTestCase {
    func testWarmUp_skippedWhenTheSettingIsOff() {
        let env = WireUp.bootstrap(options: makeWireUpTestOptions())
        env.settings.connectionPreWarmingEnabled = false
        let prewarmer = ConnectionPrewarmer(settings: env.settings, permissions: env.permissions) {}

        XCTAssertFalse(prewarmer.warmUpIfEnabled())
    }
}

@MainActor
final class ReprocessingCoordinatorTests: XCTestCase {
    private final class FakeHost: ReprocessingHost {
        var activeSession: ActiveSession?
        var published: [MainManager.State] = []
        var feedbackClears = 0
        var releases = 0
        var missingKeys: [(phase: HistoryError.Phase, message: String)] = []

        func adopt(_ session: ActiveSession) { activeSession = session }
        func releaseActiveSession() {
            releases += 1
            activeSession = nil
        }
        func publish(_ state: MainManager.State) { published.append(state) }
        func publishFailure(_ message: String) { published.append(.failed(message)) }
        func clearDeliveryFeedback() { feedbackClears += 1 }
        func makeDiagnosticContext() -> HistoryDiagnosticContext {
            HistoryDiagnosticContext(
                appVersion: "1", appBuild: "1", operatingSystem: "test", processIdentifier: 1,
                microphonePermission: "granted", inputDeviceName: "test", providerLabel: "test", latencyTier: "test",
                transcriptionMode: "test", transcriptionModel: "test", postProcessingModel: "test", speedMode: "test"
            )
        }
        func failForMissingAPIKey(_ session: ActiveSession, phase: HistoryError.Phase, message: String) async {
            missingKeys.append((phase, message))
            activeSession = nil
        }
        func recordDeliveryFailure(
            _ error: Error, headline: String, remedy: DeliverySettingsRemedy?, finalText: String,
            session: ActiveSession
        ) async {}
        func recordInsertion(of text: String, range: VoiceEditTextRange?, target: TextOutputTarget?) {}
        func completeRetryDelivery(remedy: DeliverySettingsRemedy?) {}
    }

    func testRetry_withoutAKeyAdoptsASessionAndReportsTheMissingKey() async {
        let env = WireUp.bootstrap(options: makeWireUpTestOptions())
        env.settings.postProcessingModel = "openai/gpt-4o-mini"
        let coordinator = ReprocessingCoordinator(
            settings: env.settings,
            permissions: env.permissions,
            transcription: env.transcription,
            text: env.main.text,
            history: env.history,
            hud: env.hud
        )
        let host = FakeHost()
        coordinator.host = host
        let entry = PostProcessingRetryStore.Entry(
            transcriptionResult: TranscriptionResult(
                text: "retry me", segments: [], confidence: nil, duration: 1, modelIdentifier: "m",
                cost: nil, rawPayload: nil, debugInfo: nil
            ),
            recordingSummary: nil,
            personalCorrections: nil,
            lexiconContext: .empty,
            originalHistoryItemID: nil
        )

        await coordinator.retryPostProcessing(with: entry)

        XCTAssertEqual(host.published, [.processing])
        XCTAssertEqual(host.feedbackClears, 1)
        XCTAssertEqual(host.missingKeys.map(\.phase), [.postProcessing])
        XCTAssertNil(host.activeSession, "The missing-key path retires the session")
        XCTAssertEqual(host.releases, 0, "and is the only release")
    }
}
