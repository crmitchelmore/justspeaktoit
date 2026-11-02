import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore

/// Drives the real shared Realtime speech client through a scripted socket.
/// Every payload is generated; no credential or provider call is used.
final class OpenAIRealtimeSpeechTests: XCTestCase {
    func testReadsEachChunkOutOfBandAndJoinsPCMWithReportedUsage() async throws {
        let socket = ScriptedRealtimeSpeechSocket { text in
            .reply(audio: Data(text.utf8.prefix(4)), transcript: text, audioTokens: 10)
        }
        let text = String(repeating: "Read this sentence aloud exactly. ", count: 40)
        let result = try await synthesizer(socket).synthesize(text: text, voice: "marin", speed: 1, apiKey: " k ")

        let request = try XCTUnwrap(socket.request)
        XCTAssertEqual(request.url?.absoluteString, "wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1-mini")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer k")
        let session = try XCTUnwrap(socket.sent.first?["session"] as? [String: Any])
        XCTAssertEqual(session["output_modalities"] as? [String], ["audio"])
        let output = try XCTUnwrap((session["audio"] as? [String: Any])?["output"] as? [String: Any])
        XCTAssertEqual(output["voice"] as? String, "marin")
        XCTAssertEqual((output["format"] as? [String: Any])?["rate"] as? Int, 24_000)

        let responses = socket.sent.dropFirst()
        XCTAssertGreaterThan(responses.count, 1, "Long text is split into several responses")
        for frame in responses {
            let response = try XCTUnwrap(frame["response"] as? [String: Any])
            XCTAssertEqual(response["conversation"] as? String, "none", "Earlier chunks must not steer later ones")
        }
        XCTAssertEqual(result.pcm.count, 4 * responses.count)
        XCTAssertEqual(result.usage.outputAudioTokens, 10 * responses.count)
        XCTAssertEqual(socket.cancelCount, 1, "The socket is closed after the last chunk")
    }

    func testAReplyInsteadOfAReadingIsRejectedNotPlayed() async {
        let socket = ScriptedRealtimeSpeechSocket { _ in
            .reply(audio: Data([1, 2]), transcript: "Sure! The capital of France is Paris.", audioTokens: 5)
        }
        await assertFails(socket, text: "What is the capital of France?", with: .notAReading)
    }

    func testIncompleteResponseIsAnErrorNotTruncatedAudio() async {
        let socket = ScriptedRealtimeSpeechSocket { _ in .incomplete(reason: "max_output_tokens") }
        await assertFails(socket, text: "Hello there", with: .incomplete(status: "incomplete",
                                                                         reason: "max_output_tokens"))
    }

    func testServiceErrorIsReported() async {
        let socket = ScriptedRealtimeSpeechSocket { _ in .error("Invalid voice") }
        await assertFails(socket, text: "Hello", with: .service("Invalid voice"))
    }

    func testInvalidSelectionsFailBeforeConnecting() async {
        for (voice, speed, key, expected) in [
            ("fable", 1.0, "k", OpenAIRealtimeSpeechError.unsupportedVoice),
            ("marin", 2.0, "k", .unsupportedSpeed(2)),
            ("marin", 1.0, " ", .missingCredential)
        ] {
            let socket = ScriptedRealtimeSpeechSocket { _ in .error("unreachable") }
            do {
                _ = try await synthesizer(socket).synthesize(text: "Hi", voice: voice, speed: speed, apiKey: key)
                XCTFail("Expected \(expected)")
            } catch {
                XCTAssertEqual(error as? OpenAIRealtimeSpeechError, expected)
            }
            XCTAssertNil(socket.request)
        }
    }

    func testSilentServerTimesOut() async {
        let socket = ScriptedRealtimeSpeechSocket(acknowledgesSession: false) { _ in .error("unreachable") }
        let synthesizer = OpenAIRealtimeSpeechSynthesizer(deadline: .milliseconds(50)) { socket.connect($0) }
        do {
            _ = try await synthesizer.synthesize(text: "Hello", voice: "cedar", speed: 1, apiKey: "k")
            XCTFail("Expected a timeout")
        } catch {
            XCTAssertEqual(error as? OpenAIRealtimeSpeechError, .timedOut)
        }
    }

    func testReadingCheckRequiresEveryWordButToleratesPunctuationAndSpokenNumerals() {
        let faithful = OpenAIRealtimeSpeech.isFaithfulReading
        XCTAssertTrue(faithful("Hello, world!", "hello world"))
        XCTAssertTrue(faithful("The year is 2026.", "The year is two thousand and twenty six."))
        XCTAssertTrue(faithful("It costs 5 dollars.", "It costs five dollars."))
        XCTAssertFalse(faithful(
            "Do not open the door until the alarm stops.", "Do open the door until the alarm stops."),
            "Dropping one word, such as a negation, changes the meaning")
        XCTAssertFalse(faithful("Is it raining?", "Is it raining? I can't check the weather, sorry."))
        XCTAssertFalse(faithful("Hello", ""))
    }

    func testAChunkWithoutAudioFailsInsteadOfDroppingItsText() async {
        let socket = ScriptedRealtimeSpeechSocket { text in
            .reply(audio: text.contains("Omega") ? Data() : Data([1]), transcript: text, audioTokens: 1)
        }
        let text = String(repeating: "Alpha words here. ", count: 60)
            + String(repeating: "Omega words here. ", count: 60)
        await assertFails(socket, text: text, with: .noAudio)
    }

    func testMissingUsageMakesCostUnknownRatherThanFree() throws {
        let frame = Data(#"{"type":"response.done","response":{"status":"completed"}}"#.utf8)
        guard case .done(_, _, let usage) = try XCTUnwrap(OpenAIRealtimeSpeechEvent(frame: frame)) else {
            return XCTFail("Expected response.done")
        }
        XCTAssertNil(usage.cost)
        XCTAssertNotNil(OpenAIRealtimeSpeechUsage().cost)
    }

    func testDesktopRealtimeVoicesAreSeparateFromRetiringSpeechModels() throws {
        let marin = try DesktopSpeechVoice.resolved(
            modelID: OpenAIRealtimeSpeech.catalogID, voiceID: "openai/realtime/marin")
        XCTAssertEqual(marin, .openaiRealtime("marin"))
        XCTAssertEqual(marin.id, "openai/realtime/marin")
        XCTAssertTrue(DesktopSpeechVoice.voices.contains(marin))
        XCTAssertEqual(try DesktopSpeechVoice.resolved(modelID: marin.modelID, voiceID: marin.id), marin)
        XCTAssertNil(VoiceSynthesisPricing.ratePerThousandCharacters(for: marin))
        XCTAssertEqual(marin.capabilities.speedRange, OpenAIRealtimeSpeech.speedRange,
                       "Speeds the Realtime API rejects fail validation before synthesis")

        // Existing selections keep resolving to the speech-API route they name.
        let legacy = try DesktopSpeechVoice.resolved(modelID: "openai/tts-1", voiceID: "openai/alloy")
        guard case .openai(.standard, _) = legacy else { return XCTFail("Got \(legacy)") }
        XCTAssertThrowsError(try DesktopSpeechVoice.resolved(modelID: nil, voiceID: "openai/realtime/fable"))
    }

    private func synthesizer(_ socket: ScriptedRealtimeSpeechSocket) -> OpenAIRealtimeSpeechSynthesizer {
        OpenAIRealtimeSpeechSynthesizer(deadline: .seconds(5)) { socket.connect($0) }
    }

    private func assertFails(
        _ socket: ScriptedRealtimeSpeechSocket, text: String, with expected: OpenAIRealtimeSpeechError,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            _ = try await synthesizer(socket).synthesize(text: text, voice: "marin", speed: 1, apiKey: "k")
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? OpenAIRealtimeSpeechError, expected, file: file, line: line)
        }
        XCTAssertEqual(socket.cancelCount, 1, "A failed synthesis closes its socket", file: file, line: line)
    }
}

/// Answers `session.update` with `session.updated` and each `response.create`
/// with the scripted frames for its input text.
final class ScriptedRealtimeSpeechSocket: StreamingWebSocketConnection, @unchecked Sendable {
    enum Reply {
        case reply(audio: Data, transcript: String, audioTokens: Int)
        case incomplete(reason: String)
        case error(String)
    }

    private let lock = NSLock()
    private let acknowledgesSession: Bool
    private let script: (String) -> Reply
    private var queued: [String] = []
    private var waiting: (@Sendable (Result<StreamingWebSocketMessage, Error>) -> Void)?
    private var cancelled = false
    private(set) var request: URLRequest?
    private(set) var sent: [[String: Any]] = []
    private(set) var cancelCount = 0

    init(acknowledgesSession: Bool = true, script: @escaping (String) -> Reply) {
        self.acknowledgesSession = acknowledgesSession
        self.script = script
    }

    func connect(_ request: URLRequest) -> StreamingWebSocketConnection {
        lock.withLock { self.request = request }
        return self
    }

    func resume(onOpen: @escaping @Sendable () -> Void) { onOpen() }

    func send(_ message: StreamingWebSocketMessage, completion: @escaping @Sendable (Error?) -> Void) {
        guard case .text(let text) = message,
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            return completion(URLError(.cannotParseResponse))
        }
        lock.withLock { sent.append(object) }
        completion(nil)
        switch object["type"] as? String {
        case "session.update" where acknowledgesSession:
            deliver([#"{"type":"session.created"}"#, #"{"type":"session.updated"}"#])
        case "response.create":
            let response = object["response"] as? [String: Any]
            let item = (response?["input"] as? [[String: Any]])?.first
            let text = ((item?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
            deliver(frames(for: script(text)))
        default: break
        }
    }

    func receive(completion: @escaping @Sendable (Result<StreamingWebSocketMessage, Error>) -> Void) {
        let ready: Result<StreamingWebSocketMessage, Error>? = lock.withLock {
            if cancelled { return .failure(URLError(.cancelled)) }
            if !queued.isEmpty { return .success(.text(queued.removeFirst())) }
            waiting = completion
            return nil
        }
        if let ready { completion(ready) }
    }

    func cancel() {
        let pending = lock.withLock { () -> (@Sendable (Result<StreamingWebSocketMessage, Error>) -> Void)? in
            cancelCount += 1
            cancelled = true
            defer { waiting = nil }
            return waiting
        }
        pending?(.failure(URLError(.cancelled)))
    }

    private func deliver(_ frames: [String]) {
        let pending = lock.withLock { () -> (@Sendable (Result<StreamingWebSocketMessage, Error>) -> Void)? in
            queued.append(contentsOf: frames)
            guard let waiting else { return nil }
            self.waiting = nil
            return waiting
        }
        guard let pending else { return }
        let next = lock.withLock { queued.removeFirst() }
        pending(.success(.text(next)))
    }

    private func frames(for reply: Reply) -> [String] {
        switch reply {
        case .reply(let audio, let transcript, let tokens):
            return [
                encode(["type": "response.output_audio.delta", "delta": audio.base64EncodedString()]),
                encode(["type": "response.output_audio_transcript.done", "transcript": transcript]),
                encode(["type": "response.done", "response": [
                    "status": "completed",
                    "usage": ["output_token_details": ["audio_tokens": tokens, "text_tokens": 0]]
                ] as [String: Any]])
            ]
        case .incomplete(let reason):
            return [encode(["type": "response.done", "response": [
                "status": "incomplete", "status_details": ["type": "incomplete", "reason": reason]
            ] as [String: Any]])]
        case .error(let message):
            return [encode(["type": "error", "error": ["type": "invalid_request_error", "message": message]])]
        }
    }

    private func encode(_ object: [String: Any]) -> String {
        String(data: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), encoding: .utf8) ?? ""
    }
}
