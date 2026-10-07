import Foundation
import SpeakCore
import SpeakDesktop
import XCTest

final class DesktopLiveLanguageRequestTests: XCTestCase {
    func testDeepgramHintUsesTheSelectedModelsWireParameter() throws {
        for (identifier, parameter) in [
            ("deepgram/nova-3-streaming", "language"),
            ("deepgram/flux-general-multi-streaming", "language_hint")
        ] {
            let factory = AssemblyAISocketFactory()
            let client = try makeClient(identifier, language: "fr_FR", factory: factory)
            defer { client.cancel() }
            let query = try requestQuery(factory)
            XCTAssertEqual(query[parameter], "fr", identifier)
            XCTAssertNil(query[parameter == "language" ? "language_hint" : "language"], identifier)
        }
    }

    func testUnsupportedModelsAndAutomaticNeverReceiveLanguageFields() throws {
        for identifier in ["deepgram/flux-general-en-streaming", AssemblyAIModels.universal35ProStreamingID] {
            let factory = AssemblyAISocketFactory()
            let client = try makeClient(identifier, language: "fr_FR", factory: factory)
            defer { client.cancel() }
            let query = try requestQuery(factory)
            XCTAssertNil(query["language"])
            XCTAssertNil(query["language_hint"])
            XCTAssertNil(query["language_code"])
        }
        for identifier in ["deepgram/nova-3-streaming", "deepgram/flux-general-multi-streaming"] {
            let factory = AssemblyAISocketFactory()
            let client = try makeClient(identifier, language: "automatic", factory: factory)
            defer { client.cancel() }
            let query = try requestQuery(factory)
            XCTAssertNil(query["language"])
            XCTAssertNil(query["language_hint"])
        }
    }

    func testOpenAILanguageUsesEachModelsCanonicalSessionSchema() throws {
        for identifier in [
            OpenAITranscriptionModels.gptLiveTranscribeStreamingCatalogID,
            "openai/gpt-realtime-whisper-streaming", "openai/gpt-4o-mini-transcribe-streaming",
            "openai/gpt-4o-transcribe-streaming"
        ] {
            let factory = AssemblyAISocketFactory()
            let client = try makeClient(identifier, language: "fr_FR", factory: factory)
            defer { client.cancel() }
            let socket = try XCTUnwrap(factory.sockets.first)
            XCTAssertTrue(socket.controls.isEmpty, "Language configuration waits for the actual handshake")
            socket.open()
            let transcription = try transcriptionInput(socket)
            if identifier == OpenAITranscriptionModels.gptLiveTranscribeStreamingCatalogID {
                XCTAssertEqual(transcription["languages"] as? [String], ["fr"])
                XCTAssertNil(transcription["language"])
            } else {
                XCTAssertEqual(transcription["language"] as? String, "fr")
                XCTAssertNil(transcription["languages"])
            }
        }
    }

    func testOpenAIAutomaticOmitsBothLanguageFields() throws {
        let factory = AssemblyAISocketFactory()
        let client = try makeClient(
            OpenAITranscriptionModels.gptLiveTranscribeStreamingCatalogID, language: "automatic", factory: factory
        )
        defer { client.cancel() }
        let socket = try XCTUnwrap(factory.sockets.first)
        socket.open()
        let transcription = try transcriptionInput(socket)
        XCTAssertNil(transcription["languages"])
        XCTAssertNil(transcription["language"])
    }
}

private extension DesktopLiveLanguageRequestTests {
    func makeClient(
        _ model: String, language: String?, factory: AssemblyAISocketFactory
    ) throws -> any FinalizingStreamingTranscriptionClient {
        let client = try XCTUnwrap(DesktopLiveTranscription.makeClient(
            model: model, apiKey: "synthetic", language: language, makeConnection: { factory.make($0) }
        ))
        client.start(onTranscript: { _, _ in }, onError: { XCTFail("Unexpected error: \($0)") })
        return client
    }

    func requestQuery(_ factory: AssemblyAISocketFactory) throws -> [String: String] {
        let url = try XCTUnwrap(factory.requests.first?.url)
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    func transcriptionInput(_ socket: AssemblyAITestSocket) throws -> [String: Any] {
        let session = try XCTUnwrap(socket.sessionUpdate?["session"] as? [String: Any])
        let input = try XCTUnwrap((session["audio"] as? [String: Any])?["input"] as? [String: Any])
        return try XCTUnwrap(input["transcription"] as? [String: Any])
    }
}
