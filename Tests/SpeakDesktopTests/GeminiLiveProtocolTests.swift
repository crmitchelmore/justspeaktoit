import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore

/// The Gemini Live wire contract the shared client speaks on every platform:
/// the handshake request, the setup and audio frames, the documented language
/// codes, and the ordered events it reads from each server message.
final class GeminiLiveProtocolTests: XCTestCase {
    func testRequestIsTheDocumentedEndpointWithTheKeyInItsQueryOnly() throws {
        let request = try XCTUnwrap(GeminiLiveProtocol.webSocketRequest(apiKey: "  synthetic-key \n"))
        let url = try XCTUnwrap(request.url)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "wss")
        XCTAssertEqual(components.host, "generativelanguage.googleapis.com")
        XCTAssertEqual(components.path, "/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent")
        XCTAssertEqual(components.queryItems, [URLQueryItem(name: "key", value: "synthetic-key")])
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(url, GeminiLiveClient.webSocketURL(apiKey: "synthetic-key"))
        XCTAssertNil(GeminiLiveProtocol.webSocketRequest(apiKey: " \n"))
    }

    func testSetupIsTranscriptionOnlyWithServerActivityDetection() throws {
        let setup = try Self.setup(language: nil)
        XCTAssertEqual(setup["model"] as? String, "models/gemini-3.5-transcribe-live")
        XCTAssertEqual((setup["generationConfig"] as? [String: Any])?["responseModalities"] as? [String], ["TEXT"])
        let transcription = try XCTUnwrap(setup["inputAudioTranscription"] as? [String: Any])
        XCTAssertEqual(transcription["mode"] as? String, "VERBATIM")
        XCTAssertEqual(transcription["languageCodes"] as? [String], [], "An empty list detects the language")
        XCTAssertNil(transcription["customVocabulary"])
        let realtime = try XCTUnwrap(setup["realtimeInputConfig"] as? [String: Any])
        XCTAssertEqual((realtime["automaticActivityDetection"] as? [String: Any])?["disabled"] as? Bool, false)
    }

    /// The Live model lists region-qualified BCP-47 codes. A selection maps to
    /// one only when it is listed (or is the listed spelling of the same
    /// language and region); anything else is detected instead.
    func testSelectionsMapOnlyToTheLiveModelsDocumentedCodes() {
        let expected: [String: String?] = [
            "en_GB": "en-GB", "en_US": "en-US", "fr_FR": "fr-FR", "de_DE": "de-DE", "ja_JP": "ja-JP",
            "ko_KR": "ko-KR", "hi_IN": "hi-IN", "pt_BR": "pt-BR", "pt_PT": "pt-PT", "ru_RU": "ru-RU",
            "zh_CN": "cmn-Hans-CN", "zh-Hans_CN": "cmn-Hans-CN", "es_MX": "es-419", "es_419": "es-419",
            "it_IT": "it-IT", "en_GB@calendar=gregorian": "en-GB", "EN_gb": "en-GB",
            "en_AU": nil, "en_CA": nil, "es_ES": nil, "zh_TW": nil, "zh-Hant_TW": nil, "ar_SA": nil,
            "xx_YY": nil, "automatic": nil, "Automatic": nil, "auto": nil, "": nil, "  ": nil
        ]
        for (selection, code) in expected {
            XCTAssertEqual(GeminiTranscribeModels.liveLanguageCode(for: selection), code, selection)
        }
        XCTAssertNil(GeminiTranscribeModels.liveLanguageCode(for: nil))
    }

    func testEveryCatalogueLanguageSendsADocumentedCodeOrDetects() throws {
        for option in TranscriptionLanguageCatalog.options {
            let codes = try XCTUnwrap(try Self.setup(language: option.id)["inputAudioTranscription"] as? [String: Any])
            let sent = try XCTUnwrap(codes["languageCodes"] as? [String], option.id)
            XCTAssertLessThanOrEqual(sent.count, 1, option.id)
            for code in sent {
                XCTAssertTrue(GeminiTranscribeModels.liveLanguageCodes.contains(code), "\(option.id) sent \(code)")
                XCTAssertNotEqual(code, option.id, "\(option.id) was sent as the stored locale")
            }
        }
        XCTAssertEqual(GeminiTranscribeModels.liveLanguageCodes.count, 83, "The documented table lists 83 codes")
    }

    func testAudioIsBase64PCMWithTheRateInItsMIMEType() throws {
        let pcm = Data((0..<3_200).map { UInt8(truncatingIfNeeded: $0 * 7) })
        let message = GeminiLiveProtocol.audioMessage(pcm, sampleRate: 16_000)
        XCTAssertEqual(GeminiLiveClient.audioChunkJSON(pcm, sampleRate: 16_000), message)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any])
        let audio = try XCTUnwrap((object["realtimeInput"] as? [String: Any])?["audio"] as? [String: Any])
        XCTAssertEqual(audio["mimeType"] as? String, "audio/pcm;rate=16000")
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(audio["data"] as? String)), pcm)
        XCTAssertEqual(GeminiLiveProtocol.audioStreamEnd, #"{"realtimeInput":{"audioStreamEnd":true}}"#)
    }

    func testEventsAreDecodedInTheOrderTheClientAppliesThem() {
        XCTAssertEqual(events(#"{"setupComplete":{}}"#), [.setupComplete])
        XCTAssertEqual(events(#"{"serverContent":{"interimInputTranscription":{"text":" Hello wor "}}}"#),
                       [.interimTranscript("Hello wor")])
        XCTAssertEqual(events(#"{"serverContent":{"inputTranscription":{"text":"Hello."},"turnComplete":true}}"#),
                       [.finalTranscript("Hello."), .turnComplete])
        XCTAssertEqual(
            events(#"{"serverContent":{"inputTranscription":{"text":"A."},"interimInputTranscription":{"text":"b"}}}"#),
            [.interimTranscript("b"), .finalTranscript("A.")],
            "An interim never outlives the final of the same message"
        )
        XCTAssertEqual(events(#"{"serverContent":{"inputTranscription":{}}}"#), [.finalTranscript("")],
                       "An utterance can end without words")
        XCTAssertEqual(events(#"{"serverContent":{"interimInputTranscription":{"text":"  "}}}"#), [])
        XCTAssertEqual(events(#"{"goAway":{"timeLeft":"10s"}}"#), [.goAway])
        XCTAssertEqual(
            events(#"{"error":{"code":429,"message":"quota","status":"RESOURCE_EXHAUSTED"},"setupComplete":{}}"#),
            [.failure(code: 429, status: "RESOURCE_EXHAUSTED", message: "quota")]
        )
        XCTAssertEqual(GeminiLiveProtocol.events(in: Data(#"{"setupComplete":{}}"#.utf8)), [.setupComplete],
                       "Binary frames carry the same JSON")
    }

    /// The output transcription is the model speaking; Speak never requests a
    /// response, and neither it nor metadata may be mistaken for dictation.
    func testUnrelatedAndMalformedMessagesCarryNoEvents() {
        for frame in [
            #"{"serverContent":{"outputTranscription":{"text":"assistant speech"}}}"#,
            #"{"usageMetadata":{"totalTokenCount":12}}"#, #"{"sessionResumptionUpdate":{"resumable":false}}"#,
            #"{"serverContent":{"generationComplete":true}}"#, "{ not json", "[]", ""
        ] {
            XCTAssertEqual(events(frame), [], frame)
        }
    }

    func testTransportFailuresMapToCloseStatusesKeysAndQuota() {
        XCTAssertEqual(GeminiLiveProtocol.connectionError(GeminiTestPeerClose(webSocketCloseCode: 1_011))
            as? GeminiLiveStreamingError, .closed(code: 1_011))
        XCTAssertEqual(GeminiLiveProtocol.connectionError(GeminiTestPeerClose(webSocketCloseCode: 1_000))
            as? GeminiLiveStreamingError, .closed(code: 1_000), "Gemini never ends a stream by closing it")
        let rejected = NSError(domain: "transport", code: 0, userInfo: [NSLocalizedDescriptionKey: "HTTP 403 Forbidden"])
        guard case StreamingClientError.invalidAPIKey(let provider)? =
            GeminiLiveProtocol.connectionError(rejected) as? StreamingClientError else {
            return XCTFail("A rejected handshake is a rejected key")
        }
        XCTAssertEqual(provider, "Google Gemini")
        let quota = NSError(domain: "transport", code: 429)
        XCTAssertEqual(GeminiLiveProtocol.connectionError(quota) as? GeminiLiveError,
                       .rateLimited(quota.localizedDescription))
        let dropped = URLError(.networkConnectionLost)
        XCTAssertEqual((GeminiLiveProtocol.connectionError(dropped) as? URLError)?.code, .networkConnectionLost)
    }

    // MARK: - Helpers

    private func events(_ frame: String) -> [GeminiLiveEvent] { GeminiLiveProtocol.events(in: Data(frame.utf8)) }

    private static func setup(language: String?) throws -> [String: Any] {
        let json = try XCTUnwrap(GeminiLiveClient.setupMessageJSON(language: language))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        return try XCTUnwrap(object["setup"] as? [String: Any])
    }
}
