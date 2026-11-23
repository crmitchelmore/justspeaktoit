import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakTestSupport
import XCTest
@testable import SpeakCore

final class VoiceStudioClientTests: XCTestCase {
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        session = StubURLProtocol.makeSession()
    }

    override func tearDown() {
        session.invalidateAndCancel()
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testVoiceboxConnectionDiscoveryAndSynthesis() async throws {
        let wavPayload = try VoiceStudioTestAudio.makePCM16MonoWAV(sampleRate: 24_000, frames: 1_200)
        let config = VoiceStudioConfiguration(enabled: true, kind: .voicebox)
        installVoiceboxStub(wavPayload: wavPayload)

        let probe = try await VoiceStudioAPI.testConnection(configuration: config, apiKey: nil, session: session)
        XCTAssertEqual(probe.studioVersion, "0.4.2")
        XCTAssertEqual(probe.voiceCount, 1)
        XCTAssertTrue(probe.detailMessage.contains("0.4.2"))

        let inventory = try await VoiceStudioAPI.listVoices(configuration: config, apiKey: nil, session: session)
        let alice = try XCTUnwrap(inventory.voices.first)
        XCTAssertEqual(alice.id, "studio/voicebox/alice-1")
        XCTAssertEqual(alice.sampleCount, 3)

        let spoken = try await VoiceStudioAPI.synthesize(
            text: "Hello from Voicebox.",
            voice: alice,
            configuration: config,
            apiKey: nil,
            session: session
        )
        XCTAssertEqual(spoken.sampleRate, 24_000)
    }

    func testVoiceboxProfilePushRequiresExplicitConfirmation() async throws {
        let wavPayload = try VoiceStudioTestAudio.makePCM16MonoWAV(sampleRate: 24_000, frames: 1_200)
        let config = VoiceStudioConfiguration(enabled: true, kind: .voicebox)
        installVoiceboxStub(wavPayload: wavPayload)

        let unconfirmedPush = VoiceStudioProfilePushRequest(
            name: "Owner Voice",
            audioData: wavPayload,
            userConfirmedCopy: false
        )
        do {
            _ = try await VoiceStudioAPI.pushProfile(
                unconfirmedPush, configuration: config, apiKey: nil, session: session
            )
            XCTFail("Expected missingProfilePushConfirmation")
        } catch {
            XCTAssertEqual(error as? VoiceStudioError, .missingProfilePushConfirmation)
        }

        let confirmedPush = VoiceStudioProfilePushRequest(
            name: "Owner Voice",
            audioData: wavPayload,
            transcript: "Sample line.",
            language: "en",
            userConfirmedCopy: true
        )
        let pushed = try await VoiceStudioAPI.pushProfile(
            confirmedPush, configuration: config, apiKey: nil, session: session
        )
        XCTAssertEqual(pushed.id, "studio/voicebox/pushed-2")
    }

    func testVoiceStudioListFallbackAndSynthesisWithUsageCapture() async throws {
        let wavPayload = try VoiceStudioTestAudio.makePCM16MonoWAV(sampleRate: 24_000, frames: 960)
        let config = VoiceStudioConfiguration(enabled: true, kind: .voiceStudio)
        installVoiceStudioStub(wavPayload: wavPayload)

        let probe = try await VoiceStudioAPI.testConnection(configuration: config, apiKey: nil, session: session)
        XCTAssertEqual(probe.studioVersion, "1.2.0")
        XCTAssertEqual(probe.voiceCount, 1)

        let inventory = try await VoiceAccountInventory.fetchStudio(
            configuration: config, session: session, credential: { "" }
        )
        let voice = try XCTUnwrap(inventory.desktopVoices.first)
        XCTAssertEqual(voice.id, "studio/voicestudio/narrator")

        let source = try VoiceOutputSourceSnapshot(source: .typedText, text: "Read aloud line.")
        let selection = try DesktopSpeechSelection(
            voice: voice, options: VoiceSynthesisOptions(), accountInventory: inventory,
            studioConfiguration: config
        )
        let capture = VoiceSynthesisUsage.Capture(operation: .generate, source: .typedText, historyRecordID: nil)
        let synthesizedWAV = try await VoiceSynthesisUsage.$capture.withValue(capture) {
            try await DesktopSpeechSynthesis(session: self.session).synthesize(
                source, selection: selection, credential: { "" }
            )
        }
        XCTAssertFalse(synthesizedWAV.isEmpty)
        let usage = try XCTUnwrap(capture.records.first)
        XCTAssertEqual(usage.outcome, .completed)
        XCTAssertNil(usage.estimatedCostUSD)
    }

    func testGPTSoVITSHealthReadinessAndTTSSynthesis() async throws {
        let wavPayload = try VoiceStudioTestAudio.makePCM16MonoWAV(sampleRate: 32_000, frames: 1_600)
        let incompleteConfig = VoiceStudioConfiguration(enabled: true, kind: .gptSoVITS)
        installGPTSoVITSStub(wavPayload: wavPayload)

        let probeIncomplete = try await VoiceStudioAPI.testConnection(
            configuration: incompleteConfig, apiKey: nil, session: session
        )
        XCTAssertFalse(probeIncomplete.gptSoVITSConfigured)
        XCTAssertEqual(probeIncomplete.studioVersion, "v2")

        let readyConfig = VoiceStudioConfiguration(
            enabled: true,
            kind: .gptSoVITS,
            baseURLString: "http://127.0.0.1:9880",
            gptSoVITSReferenceAudioPath: "/tmp/ref.wav",
            gptSoVITSReferencePromptText: "Reference words.",
            gptSoVITSReferencePromptLanguage: "en",
            gptSoVITSTextLanguage: "en"
        )
        let voice = try DesktopSpeechVoice.resolved(
            modelID: "studio/gpt-sovits",
            voiceID: "studio/gpt-sovits/reference"
        )
        let selection = try DesktopSpeechSelection(
            voice: voice, options: VoiceSynthesisOptions(), accountInventory: nil, studioConfiguration: readyConfig
        )
        let source = try VoiceOutputSourceSnapshot(source: .typedText, text: "Speak with reference.")
        let outputWAV = try await DesktopSpeechSynthesis(session: session).synthesize(
            source, selection: selection, credential: { "" }
        )
        let canonical = try DeepgramSpeechWAV.canonical(outputWAV, sampleRate: 24_000, requireComplete: true)
        XCTAssertEqual(canonical.frameCount, 1_200)
    }

    func testExplicitErrorsSurfaceSanitizedDetailsWithoutFallback() async throws {
        let config = VoiceStudioConfiguration(
            enabled: true,
            kind: .voiceStudio,
            baseURLString: "https://studio.example.com"
        )
        let secretKey = "top-secret-token-xyz"

        StubURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            return try Self.jsonResponse(url: url, object: ["detail": "Bad request \(secretKey)"], statusCode: 500)
        }
        do {
            _ = try await VoiceStudioAPI.testConnection(configuration: config, apiKey: secretKey, session: session)
            XCTFail("Expected HTTP 500 error")
        } catch let error as VoiceStudioError {
            XCTAssertTrue(error.localizedDescription.contains("VoiceStudio returned HTTP 500"))
            XCTAssertFalse(error.localizedDescription.contains(secretKey), "Secret leaked in error description")
        }

        StubURLProtocol.handler = { _ in .fail(URLError(.cannotConnectToHost)) }
        let voiceboxConfig = VoiceStudioConfiguration(enabled: true, kind: .voicebox)
        do {
            _ = try await VoiceStudioAPI.testConnection(configuration: voiceboxConfig, apiKey: nil, session: session)
            XCTFail("Expected studioNotRunning")
        } catch let error as VoiceStudioError {
            XCTAssertTrue(error.localizedDescription.contains("Voicebox isn't running at http://127.0.0.1:17493"))
        }

        StubURLProtocol.handler = { _ in .fail(URLError(.serverCertificateUntrusted)) }
        do {
            _ = try await VoiceStudioAPI.testConnection(configuration: config, apiKey: secretKey, session: session)
            XCTFail("Expected tlsError")
        } catch let error as VoiceStudioError {
            guard case .tlsError(.voiceStudio, _) = error else {
                return XCTFail("Expected tlsError, got \(error)")
            }
        }
    }
}

private extension VoiceStudioClientTests {
    // MARK: - Stubs

    func installVoiceboxStub(wavPayload: Data) {
        StubURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            if url.path == "/health" {
                return try Self.jsonResponse(url: url, object: ["version": "0.4.2"])
            }
            if url.path == "/profiles", request.httpMethod == "GET" {
                return try Self.jsonResponse(url: url, object: [
                    ["id": "alice-1", "name": "Alice", "language": "en", "sample_count": 3]
                ])
            }
            if url.path == "/profiles", request.httpMethod == "POST" {
                return try Self.jsonResponse(url: url, object: [
                    "id": "pushed-2", "name": "Owner Voice", "language": "en"
                ])
            }
            if url.path == "/generate", request.httpMethod == "POST" {
                let body = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: StubURLProtocol.body(of: request)) as? [String: Any]
                )
                XCTAssertEqual(body["profile_id"] as? String, "alice-1")
                XCTAssertEqual(body["text"] as? String, "Hello from Voicebox.")
                return try Self.wavResponse(url: url, data: wavPayload)
            }
            XCTFail("Unexpected Voicebox request: \(request.httpMethod ?? "?") \(url.path)")
            return .fail(URLError(.badURL))
        }
    }

    func installVoiceStudioStub(wavPayload: Data) {
        StubURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            if url.path == "/health" {
                return try Self.jsonResponse(url: url, object: ["version": "1.2.0"])
            }
            if url.path == "/v1/voices" {
                let http = try XCTUnwrap(
                    HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: [:])
                )
                return .respond(http, Data("Not Found".utf8))
            }
            if url.path == "/voices" {
                return try Self.jsonResponse(url: url, object: [
                    "voices": [["voice_id": "narrator", "name": "Narrator", "language": "en"]]
                ])
            }
            if url.path == "/v1/audio/speech", request.httpMethod == "POST" {
                let body = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: StubURLProtocol.body(of: request)) as? [String: Any]
                )
                XCTAssertEqual(body["voice"] as? String, "narrator")
                XCTAssertEqual(body["input"] as? String, "Read aloud line.")
                return try Self.wavResponse(url: url, data: wavPayload)
            }
            XCTFail("Unexpected VoiceStudio request: \(url.path)")
            return .fail(URLError(.badURL))
        }
    }

    func installGPTSoVITSStub(wavPayload: Data) {
        StubURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            if url.path == "/health" {
                let http = try XCTUnwrap(
                    HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: [:])
                )
                return .respond(http, Data())
            }
            if url.path == "/openapi.json" {
                return try Self.jsonResponse(url: url, object: ["info": ["version": "v2"]])
            }
            if url.path == "/tts", request.httpMethod == "POST" {
                let body = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: StubURLProtocol.body(of: request)) as? [String: Any]
                )
                XCTAssertEqual(body["ref_audio_path"] as? String, "/tmp/ref.wav")
                XCTAssertEqual(body["prompt_text"] as? String, "Reference words.")
                XCTAssertEqual(body["prompt_lang"] as? String, "en")
                XCTAssertEqual(body["text_lang"] as? String, "en")
                return try Self.wavResponse(url: url, data: wavPayload)
            }
            XCTFail("Unexpected GPT-SoVITS path: \(url.path)")
            return .fail(URLError(.badURL))
        }
    }

    static func jsonResponse(url: URL, object: Any, statusCode: Int = 200) throws -> StubURLProtocol.Outcome {
        let data = try JSONSerialization.data(withJSONObject: object)
        let http = try XCTUnwrap(HTTPURLResponse(
            url: url, statusCode: statusCode, httpVersion: nil, headerFields: ["Content-Type": "application/json"]
        ))
        return .respond(http, data)
    }

    static func wavResponse(url: URL, data: Data) throws -> StubURLProtocol.Outcome {
        let http = try XCTUnwrap(HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "audio/wav"]
        ))
        return .respond(http, data)
    }
}
