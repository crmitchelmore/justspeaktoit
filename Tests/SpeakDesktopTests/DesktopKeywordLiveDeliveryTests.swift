import Foundation
import XCTest
@testable import SpeakCore
import SpeakDesktop

final class DesktopKeywordLiveDeliveryTests: XCTestCase {
    func testFactoryMapsDeepgramAndScribeKeywordsWithoutChangingLocaleOrModel() throws {
        for (model, parameter) in [
            ("deepgram/nova-3-streaming", "keyterm"),
            ("deepgram/flux-general-en-streaming", "keyterm"),
            ("elevenlabs/scribe_v2_realtime-streaming", "keyterms")
        ] {
            // Use the canonical catalogue identifier for Scribe rather than accepting aliases.
            let identifier = model.hasPrefix("elevenlabs/")
                ? try XCTUnwrap(DesktopLiveTranscription.liveModels.first { $0.id.hasPrefix("elevenlabs/") }).id : model
            let factory = AssemblyAISocketFactory()
            let client = try make(identifier, factory: factory)
            defer { client.cancel() }
            let query = try XCTUnwrap(URLComponents(url: factory.requests[0].url!, resolvingAgainstBaseURL: false))
            XCTAssertEqual(query.queryItems?.filter { $0.name == parameter }.compactMap(\.value), ["Speak", "Grace"])
            XCTAssertFalse(query.queryItems?.contains { $0.name == "prompt" } ?? true)
        }
    }

    func testFactorySendsOpenAIGlossaryInExistingGAUpdateButNotToWhisper() throws {
        for model in ["openai/gpt-4o-transcribe-streaming", "openai/gpt-realtime-whisper-streaming"] {
            let factory = AssemblyAISocketFactory()
            let client = try make(model, factory: factory)
            defer { client.cancel() }
            factory.sockets[0].open()
            let update = try XCTUnwrap(factory.sockets[0].objects.first)
            let session = try XCTUnwrap(update["session"] as? [String: Any])
            let audio = try XCTUnwrap(session["audio"] as? [String: Any])
            let input = try XCTUnwrap(audio["input"] as? [String: Any])
            let transcription = try XCTUnwrap(input["transcription"] as? [String: Any])
            XCTAssertEqual(transcription["language"] as? String, "fr")
            XCTAssertEqual(transcription["prompt"] as? String, model.contains("whisper") ? nil : "Speak, Grace")
            XCTAssertEqual(factory.requests[0].url?.query, "intent=transcription")
            XCTAssertNil(factory.requests[0].value(forHTTPHeaderField: "OpenAI-Beta"))
        }
    }

    func testFactorySerializesSpeechmaticsAndSonioxVocabularyInProviderOwnedConfig() throws {
        for model in ["speechmatics/enhanced-streaming", "soniox/stt-rt-v5-streaming"] {
            let factory = AssemblyAISocketFactory()
            let client = try make(model, factory: factory)
            defer { client.cancel() }
            factory.sockets[0].open()
            let payload = try XCTUnwrap(factory.sockets[0].objects.first)
            if model.hasPrefix("speechmatics/") {
                let config = try XCTUnwrap(payload["transcription_config"] as? [String: Any])
                let terms = try XCTUnwrap(config["additional_vocab"] as? [[String: String]])
                XCTAssertEqual(terms.map { $0["content"] }, ["Speak", "Grace"])
                XCTAssertEqual(config["language"] as? String, "fr")
            } else {
                let context = try XCTUnwrap(payload["context"] as? [String: [String]])
                XCTAssertEqual(context["terms"], ["Speak", "Grace"])
                XCTAssertEqual(payload["language_hints"] as? [String], ["fr"])
                XCTAssertNil(context["text"])
            }
        }
    }

    func testAssemblyExplicitOverrideAndEmptyClearDoNotFallBackToGlobalWords() throws {
        let identifier = try XCTUnwrap(DesktopLiveTranscription.liveModels.first { $0.id.hasPrefix("assemblyai/") }).id
        for terms in [[], ["Explicit"]] {
            let factory = AssemblyAISocketFactory()
            let client = try XCTUnwrap(DesktopLiveTranscription.makeClient(
                model: identifier, apiKey: "synthetic", language: nil, azureEndpoint: "",
                options: .init(keywords: ["Global"], assemblyAIKeyterms: terms),
                makeConnection: { factory.make($0) }
            ))
            client.start(onTranscript: { _, _ in }, onError: { XCTFail("\($0)") })
            defer { client.cancel() }
            let query = try XCTUnwrap(URLComponents(url: factory.requests[0].url!, resolvingAgainstBaseURL: false))
            let value = query.queryItems?.first { $0.name == "keyterms_prompt" }?.value
            if terms.isEmpty {
                XCTAssertNil(value)
            } else {
                let encoded = Data(try XCTUnwrap(value).utf8)
                XCTAssertEqual(try JSONDecoder().decode([String].self, from: encoded), terms)
            }
        }
    }

    private func make(
        _ model: String, factory: AssemblyAISocketFactory
    ) throws -> any FinalizingStreamingTranscriptionClient {
        let client = try XCTUnwrap(DesktopLiveTranscription.makeClient(
            model: model, apiKey: "synthetic", language: "fr_FR", azureEndpoint: "",
            options: .init(keywords: ["Speak", "Grace"]), makeConnection: { factory.make($0) }
        ))
        client.start(onTranscript: { _, _ in }, onError: { XCTFail("\($0)") })
        return client
    }
}
