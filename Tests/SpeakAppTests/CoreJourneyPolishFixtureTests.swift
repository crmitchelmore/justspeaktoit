#if DEBUG
import Foundation
import SpeakCore
import XCTest

@testable import SpeakApp

@MainActor
final class CoreJourneyPolishFixtureTests: XCTestCase {
    func testProfile_EnablesOrdinaryNonstreamingSettingsWithoutChangingOtherProfiles() {
        let profile = self.makeProfile(.batchPolishSuccess)
        let off = self.makeProfile(.batchOff)
        XCTAssertTrue(profile.settings.postProcessingEnabled)
        XCTAssertEqual(profile.settings.postProcessingModel, CoreJourneyBatchScenario.polishModel)
        XCTAssertFalse(profile.settings.postProcessingStreamingEnabled)
        XCTAssertEqual(profile.settings.postProcessingTemperature, 0)
        XCTAssertTrue(profile.settings.showHUDDuringSessions)
        XCTAssertFalse(off.settings.postProcessingEnabled)
        XCTAssertFalse(off.settings.showHUDDuringSessions)
        XCTAssertNotEqual(profile.polishFixture.key, off.polishFixture.key)
    }

    func testSuccess_AdmitsActualBatchAndChatSerializationInOrder() async throws {
        let profile = self.makeProfile(.batchPolishSuccess)
        let client = profile.polishFixture.makeClient()
        let raw = try await self.transcribe(client, profile: profile)
        XCTAssertEqual(raw, CoreJourneyBatchScenario.rawA)
        let polished = try await self.polish(client, raw: raw)
        XCTAssertEqual(polished, CoreJourneyBatchScenario.polishedA)
        try self.assertSequence(["batchA", "polishA"], profile: profile)
    }

    func testFailureThenSuccess_RetainsIndependentSequencesAcrossProfiles() async throws {
        let first = self.makeProfile(.batchPolishFailureThenSuccess)
        let second = self.makeProfile(.batchPolishSuccess)
        let firstClient = first.polishFixture.makeClient()
        let secondClient = second.polishFixture.makeClient()
        let rawA = try await self.transcribe(firstClient, profile: first)
        let otherRaw = try await self.transcribe(secondClient, profile: second)
        do {
            _ = try await self.polish(firstClient, raw: rawA)
            XCTFail("The admitted first polish must return its controlled HTTP failure")
        } catch OpenRouterClientError.httpStatus(let code, let body) {
            XCTAssertEqual(code, 400)
            XCTAssertTrue(body.contains(CoreJourneyBatchScenario.failureMessage))
        }
        let otherPolished = try await self.polish(secondClient, raw: otherRaw)
        XCTAssertEqual(otherPolished, CoreJourneyBatchScenario.polishedA)
        let rawB = try await self.transcribe(firstClient, profile: first)
        XCTAssertEqual(rawB, CoreJourneyBatchScenario.rawB)
        let polishedB = try await self.polish(firstClient, raw: rawB)
        XCTAssertEqual(polishedB, CoreJourneyBatchScenario.polishedB)
        try self.assertSequence(["batchA", "polishA", "batchB", "polishB"], profile: first)
        try self.assertSequence(["batchA", "polishA"], profile: second)
    }

    func testPolish_RejectsStaleTextAndExtraNestedFieldsWithoutAdvancingSequence() throws {
        let profile = self.makeProfile(.batchPolishSuccess)
        let fixture = profile.polishFixture
        _ = try fixture.reply(to: self.audioRequest(key: fixture.key))
        for mutation in 0..<3 {
            var messages = [
                ["role": "system", "content": CoreJourneyBatchScenario.systemPrompt],
                ["role": "user", "content": TranscriptCleanupPolicy.userMessage(
                    transcript: CoreJourneyBatchScenario.rawA
                )]
            ]
            switch mutation {
            case 0: messages[1]["content"] = TranscriptCleanupPolicy.userMessage(transcript: "Stale raw text")
            case 1: messages[0]["extra"] = "Unexpected field"
            default: messages[1]["role"] = "assistant"
            }
            var request = self.request(key: fixture.key)
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": CoreJourneyBatchScenario.polishModel, "temperature": 0, "messages": messages
            ])
            XCTAssertThrowsError(try fixture.reply(to: request))
        }
        let data = try Data(contentsOf: profile.directory.appendingPathComponent("batch-http.json"))
        let result = try JSONDecoder().decode(Diagnostics.self, from: data)
        XCTAssertEqual(result.sequence, ["batchA"])
        XCTAssertEqual(result.rejectedRequests, 3)
    }

    private func transcribe(_ client: OpenRouterAPIClient, profile: CoreJourneyLaunchProfile) async throws -> String {
        try FileManager.default.createDirectory(at: profile.directory, withIntermediateDirectories: true)
        let file = profile.directory.appendingPathComponent("synthetic.wav")
        try CoreJourneyBatchFixture.audioData.write(to: file)
        return try await client.transcribeFile(at: file, model: CoreJourneyBatchFixture.model, language: nil).text
    }

    private func polish(_ client: OpenRouterAPIClient, raw: String) async throws -> String? {
        try await client.sendChat(
            systemPrompt: CoreJourneyBatchScenario.systemPrompt,
            messages: [.init(role: .user, content: TranscriptCleanupPolicy.userMessage(transcript: raw))],
            model: CoreJourneyBatchScenario.polishModel, temperature: 0
        ).messages.last?.content
    }

    private func request(key: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func audioRequest(key: String) throws -> URLRequest {
        var request = self.request(key: key)
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": CoreJourneyBatchFixture.model, "temperature": 0, "stream": false,
            "messages": [["role": "user", "content": [
                ["type": "text", "text": CoreJourneyBatchFixture.audioPrompt],
                ["type": "input_audio", "input_audio": [
                    "format": "wav", "data": CoreJourneyBatchFixture.audioData.base64EncodedString()
                ]]
            ]]]
        ])
        return request
    }

    private struct Diagnostics: Decodable {
        let sequence: [String]
        let rejectedRequests: Int
    }

    private func assertSequence(_ expected: [String], profile: CoreJourneyLaunchProfile) throws {
        let data = try Data(contentsOf: profile.directory.appendingPathComponent("batch-http.json"))
        let result = try JSONDecoder().decode(Diagnostics.self, from: data)
        XCTAssertEqual(result.sequence, expected)
        XCTAssertEqual(result.rejectedRequests, 0)
    }

    private func makeProfile(_ scenario: CoreJourneyBatchScenario) -> CoreJourneyLaunchProfile {
        let profile = CoreJourneyLaunchProfile(identifier: UUID(), runsBatchJourney: true, batchScenario: scenario)
        let fixture = profile.polishFixture
        let suiteName = profile.suiteName
        let directory = profile.directory
        let cleanup: () throws -> Void = {
            fixture.close()
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        self.addTeardownBlock(cleanup)
        return profile
    }
}
#endif
