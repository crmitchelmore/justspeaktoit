import Foundation
import SpeakTestSupport
import XCTest

@testable import SpeakApp

/// Covers which ElevenLabs endpoint and model each quality tier reaches. Eleven
/// v4 is only served through Text to Dialogue, so the highest tier must use
/// that endpoint and fall back to Eleven v3 text-to-speech when it cannot.
@MainActor
final class ElevenLabsTTSRoutingTests: XCTestCase {
    private let voice = "elevenlabs/21m00Tcm4TlvDq8ikWAM"
    private let audio = Data("mp3".utf8)

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    private func makeClient() -> ElevenLabsClient {
        let storage = SecureAppStorage(
            permissionsManager: PermissionsManager(),
            appSettings: AppSettings(),
            keychainService: "com.justspeaktoit.tests.elevenlabs.tts.\(UUID().uuidString)"
        )
        return ElevenLabsClient(secureStorage: storage, session: StubURLProtocol.makeSession())
    }

    /// Answers each request by path: `dialogueStatus` for Text to Dialogue,
    /// 200 for text-to-speech.
    private func stub(dialogueStatus: Int) {
        let audio = self.audio
        StubURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            let status = url.path.hasSuffix("/text-to-dialogue") ? dialogueStatus : 200
            return .status(status, status == 200 ? audio : Data(#"{"detail":"no"}"#.utf8), url: url)
        }
    }

    private func jsonBody(_ request: URLRequest) throws -> [String: Any] {
        let data = StubURLProtocol.body(of: request)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testHighestQuality_sendsElevenV4ThroughTextToDialogue() async throws {
        stub(dialogueStatus: 200)

        let data = try await makeClient().audioData(
            text: "Hello there", voice: voice, quality: .highest, apiKey: "xi-test")

        XCTAssertEqual(data, audio)
        let requests = StubURLProtocol.recordedRequests
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.elevenlabs.io/v1/text-to-dialogue")
        XCTAssertEqual(request.value(forHTTPHeaderField: "xi-api-key"), "xi-test")
        let body = try jsonBody(request)
        XCTAssertEqual(body["model_id"] as? String, "eleven_v4")
        let inputs = try XCTUnwrap(body["inputs"] as? [[String: String]])
        XCTAssertEqual(inputs, [["text": "Hello there", "voice_id": "21m00Tcm4TlvDq8ikWAM"]])
    }

    func testHighestQuality_fallsBackToElevenV3_whenDialogueRejectsTheRequest() async throws {
        stub(dialogueStatus: 422)

        let data = try await makeClient().audioData(
            text: "Hello there", voice: voice, quality: .highest, apiKey: "xi-test")

        XCTAssertEqual(data, audio)
        let fallback = try XCTUnwrap(StubURLProtocol.recordedRequests.last)
        XCTAssertEqual(
            fallback.url?.absoluteString,
            "https://api.elevenlabs.io/v1/text-to-speech/21m00Tcm4TlvDq8ikWAM"
        )
        XCTAssertEqual(try jsonBody(fallback)["model_id"] as? String, "eleven_v3")
    }

    func testHighestQuality_surfacesServerErrors_insteadOfSwitchingModels() async {
        stub(dialogueStatus: 500)

        do {
            _ = try await makeClient().audioData(
                text: "Hello there", voice: voice, quality: .highest, apiKey: "xi-test")
            XCTFail("A 500 from Text to Dialogue should surface as a synthesis failure")
        } catch TTSError.synthesisFailure {
            XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testHighestQuality_sendsLongTextStraightToElevenV3() async throws {
        stub(dialogueStatus: 200)
        let longText = String(repeating: "a", count: ElevenLabsTTSModels.dialogueCharacterLimit + 1)

        _ = try await makeClient().audioData(text: longText, voice: voice, quality: .highest, apiKey: "xi-test")

        let requests = StubURLProtocol.recordedRequests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.url?.path, "/v1/text-to-speech/21m00Tcm4TlvDq8ikWAM")
        XCTAssertEqual(try jsonBody(try XCTUnwrap(requests.first))["model_id"] as? String, "eleven_v3")
    }

    func testStandardAndHighQuality_useTextToSpeechModels() async throws {
        stub(dialogueStatus: 200)
        let client = makeClient()

        _ = try await client.audioData(text: "Hi", voice: voice, quality: .standard, apiKey: "xi-test")
        _ = try await client.audioData(text: "Hi", voice: voice, quality: .high, apiKey: "xi-test")

        let requests = StubURLProtocol.recordedRequests
        let expectedPath: String? = "/v1/text-to-speech/21m00Tcm4TlvDq8ikWAM"
        XCTAssertEqual(requests.map { $0.url?.path }, [expectedPath, expectedPath])
        XCTAssertEqual(
            try requests.map { try jsonBody($0)["model_id"] as? String },
            ["eleven_flash_v2_5", "eleven_multilingual_v2"]
        )
    }
}
