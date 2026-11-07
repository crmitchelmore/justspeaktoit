#if DEBUG
import Foundation
import SpeakCore
import XCTest

@testable import SpeakApp

@MainActor
final class CoreJourneyScenarioFixtureTests: XCTestCase {
    func testScenarioProfiles_SelectTheirProductionRoutesWithoutPolishing() {
        let streaming = makeProfile(.streamingOff)
        XCTAssertEqual(streaming.settings.transcriptionMode, .liveNative)
        XCTAssertEqual(streaming.settings.liveTranscriptionModel, CoreJourneyScenarioFixture.streamingModel)
        XCTAssertFalse(streaming.settings.speedMode.usesLivePolish)
        XCTAssertFalse(streaming.settings.streamingInsertionEnabled)
        XCTAssertNotNil(streaming.makeLiveControllerOverride())
        for scenario in [CoreJourneyBatchScenario.batchSilentInput, .batchMissingKeyThenRecovery, .batchOff] {
            let profile = makeProfile(scenario)
            XCTAssertEqual(profile.settings.transcriptionMode, .batchRemote, scenario.rawValue)
            XCTAssertNil(profile.makeLiveControllerOverride(), scenario.rawValue)
            XCTAssertFalse(scenario.polishes)
            XCTAssertFalse(profile.settings.postProcessingEnabled)
            XCTAssertEqual(profile.settings.textOutputMethod, .clipboardOnly)
        }
        XCTAssertTrue(makeProfile(.batchMissingKeyThenRecovery).settings.showHUDDuringSessions)
    }

    func testSilentAudio_IsAValidSilentWAVOfTheSameShape() async throws {
        let silent = CoreJourneyScenarioFixture.silentAudioData
        XCTAssertEqual(silent.count, CoreJourneyBatchFixture.audioData.count)
        XCTAssertEqual(silent.prefix(44), CoreJourneyBatchFixture.audioData.prefix(44))
        XCTAssertTrue(silent.dropFirst(44).allSatisfy { $0 == 0 })
        XCTAssertEqual(CoreJourneyBatchScenario.batchSilentInput.recordingAudio, silent)
        XCTAssertEqual(CoreJourneyBatchScenario.batchOff.recordingAudio, CoreJourneyBatchFixture.audioData)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let source = makeProfile(.batchSilentInput).makeCaptureSource()
        let start = try await source.start(in: directory)
        XCTAssertEqual(try Data(contentsOf: start.url), silent)
        _ = try await source.stop()
    }

    func testSilentRequest_IsAdmittedOnlyForSilentBytes() {
        XCTAssertTrue(CoreJourneyBatchURLProtocol.accepts(audioRequest(silentAudio()), audio: silentAudio()))
        XCTAssertFalse(CoreJourneyBatchURLProtocol.accepts(audioRequest(silentAudio())))
        XCTAssertFalse(CoreJourneyBatchURLProtocol.accepts(
            audioRequest(CoreJourneyBatchFixture.audioData), audio: silentAudio()
        ))
    }

    /// The fixture admits the real serialized silent upload and answers with no
    /// text; production then reports the empty transcript as an invalid response.
    func testSilentProfile_ProductionClientUploadsSilenceAndRejectsTheEmptyTranscript() async throws {
        let profile = makeProfile(.batchSilentInput)
        try FileManager.default.createDirectory(at: profile.directory, withIntermediateDirectories: true)
        let file = profile.directory.appendingPathComponent("silent.wav")
        try CoreJourneyScenarioFixture.silentAudioData.write(to: file)
        do {
            _ = try await profile.makeFixtureClient()
                .transcribeFile(at: file, model: CoreJourneyBatchFixture.model, language: nil)
            XCTFail("An empty provider transcript must not become deliverable text")
        } catch OpenRouterClientError.invalidResponse {
            // Reaching the decoder proves the protocol admitted the exact silent bytes.
        }
    }

    func testMissingKeyClient_ReadsTheCredentialSlotPerRequest() async throws {
        let profile = makeProfile(.batchMissingKeyThenRecovery)
        let client = profile.makeFixtureClient()
        let hasKeyBefore = await client.hasStoredAPIKey()
        XCTAssertFalse(hasKeyBefore)
        profile.credentialSlot.provide()
        let hasKeyAfter = await client.hasStoredAPIKey()
        XCTAssertTrue(hasKeyAfter)
        XCTAssertTrue(FileManager.default.fileExists(atPath: profile.directory
            .appendingPathComponent(CoreJourneyScenarioFixture.credentialAcknowledgementFileName).path))
        XCTAssertNotEqual(CoreJourneyCredentialSlot.notificationName(for: UUID()),
                          CoreJourneyCredentialSlot.notificationName(for: profile.identifier))
    }

    func testStreamingController_EmitsReplacementPartialsThenOneFinal() async throws {
        let profile = makeProfile(.streamingOff)
        let factory = try XCTUnwrap(profile.makeLiveControllerOverride())
        let controller = factory(CoreJourneyScenarioFixture.streamingModel)
        XCTAssertTrue(controller === factory("any"), "Routing probes and the session must share one controller")
        let spy = DelegateSpy()
        controller.delegate = spy
        controller.configure(language: nil, model: CoreJourneyScenarioFixture.streamingModel)
        try await controller.start()
        let deadline = Date().addingTimeInterval(5)
        while spy.partials.count < CoreJourneyScenarioFixture.streamingPartials.count, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(spy.partials, CoreJourneyScenarioFixture.streamingPartials)
        await controller.stop()
        await controller.stop()
        XCTAssertEqual(spy.finals, [CoreJourneyScenarioFixture.streamingFinal])
        XCTAssertFalse(controller.isRunning)
        let data = try Data(contentsOf: profile.directory.appendingPathComponent("streaming-live.json"))
        let diagnostics = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(diagnostics["starts"] as? Int, 1)
        XCTAssertEqual(diagnostics["stops"] as? Int, 1)
        XCTAssertEqual(diagnostics["unexpectedModels"] as? [String], [])
    }

    private func silentAudio() -> Data { CoreJourneyScenarioFixture.silentAudioData }

    private func audioRequest(_ audio: Data) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(CoreJourneyBatchFixture.fixtureKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": CoreJourneyBatchFixture.model, "temperature": 0, "stream": false,
            "messages": [["role": "user", "content": [
                ["type": "text", "text": CoreJourneyBatchFixture.audioPrompt],
                ["type": "input_audio", "input_audio": ["format": "wav", "data": audio.base64EncodedString()]]
            ]]]
        ])
        return request
    }

    private func makeProfile(_ scenario: CoreJourneyBatchScenario) -> CoreJourneyLaunchProfile {
        let profile = CoreJourneyLaunchProfile(identifier: UUID(), runsBatchJourney: true, batchScenario: scenario)
        let suiteName = profile.suiteName
        let directory = profile.directory
        addTeardownBlock {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        return profile
    }
}

@MainActor
private final class DelegateSpy: LiveTranscriptionSessionDelegate {
    var partials: [String] = []
    var finals: [String] = []

    func liveTranscriber(_ session: any LiveTranscriptionController, didUpdatePartial text: String) {
        partials.append(text)
    }

    func liveTranscriber(_ session: any LiveTranscriptionController, didUpdateWith update: LiveTranscriptionUpdate) {
        partials.append(update.text)
    }

    func liveTranscriber(_ session: any LiveTranscriptionController, didFinishWith result: TranscriptionResult) {
        finals.append(result.text)
    }

    func liveTranscriber(_ session: any LiveTranscriptionController, didFail error: Error) {}

    func liveTranscriber(_ session: any LiveTranscriptionController, didDetectUtteranceBoundary utterance: String) {}
}
#endif
