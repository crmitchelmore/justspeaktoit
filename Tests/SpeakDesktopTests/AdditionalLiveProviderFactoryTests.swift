import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakCore
@testable import SpeakDesktop
import XCTest

final class AdditionalLiveProviderFactoryTests: XCTestCase {
    func testCanonicalOptionsForwardKeywordsAndProviderControlsToTheirOwnWireFields() throws {
        let options = LiveClientOptions(
            keywords: ["SyntheticTerm"], assemblyAIKeyterms: ["AssemblyTerm"],
            modulate: .init(speakerDiarization: true, emotionSignal: true, accentSignal: true, piiPhiTagging: true),
            postStopFinalizeBudget: 3, stopGracePeriod: 2
        )
        for model in [
            GeminiTranscribeModels.liveCatalogID, MetaMuseVoiceTranscribe.liveCatalogID,
            "modulate/velma-2-stt-streaming", XAISpeechToText.liveCatalogID,
            AssemblyAIModels.universal35ProStreamingID, "cartesia/ink-2-streaming"
        ] {
            let factory = AssemblyAISocketFactory()
            let client = try XCTUnwrap(DesktopLiveTranscription.makeClient(
                model: model, apiKey: "synthetic", language: "fr_FR", azureEndpoint: "",
                options: options, makeConnection: { factory.make($0) }
            ), model)
            client.start(onTranscript: { _, _ in }, onError: { XCTFail("\(model): \($0)") })
            defer { client.cancel() }
            let socket = try XCTUnwrap(factory.sockets.first)
            socket.open()
            let request = try XCTUnwrap(factory.requests.first)
            let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
            let values = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") })
            let frame = socket.controls.first.map { Data($0.utf8) }
            let json = frame.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            switch DesktopLiveTranscription.route(forID: model)?.provider {
            case .google:
                let setup = try XCTUnwrap(json["setup"] as? [String: Any])
                let transcription = try XCTUnwrap(setup["inputAudioTranscription"] as? [String: Any])
                XCTAssertEqual(transcription["customVocabulary"] as? [String], ["SyntheticTerm"])
            case .meta:
                XCTAssertEqual(json["keywords"] as? [String], ["SyntheticTerm"])
                XCTAssertEqual((json["authorization"] as? [String: Any])?["accessToken"] as? String, "synthetic")
            case .modulate:
                for control in ["speaker_diarization", "emotion_signal", "accent_signal", "pii_phi_tagging"] {
                    XCTAssertEqual(values[control], "true")
                }
                XCTAssertEqual(request.url?.host, "platform.modulate.ai")
            case .xai:
                XCTAssertEqual(values["keyterm"], "SyntheticTerm")
            case .assemblyai:
                XCTAssertEqual(values["keyterms_prompt"], #"["AssemblyTerm"]"#)
                XCTAssertEqual(client.finalisationBudget, 10)
            case .cartesia:
                XCTAssertNotNil(client.finalisationBudget)
            default:
                XCTFail("Unexpected provider for \(model)")
            }
        }
    }

    func testOriginalPublicFactorySignaturesRemainSourceCompatible() {
        let original: (
            String, String, String?, @escaping @Sendable (URLRequest) -> any StreamingWebSocketConnection
        ) -> (any FinalizingStreamingTranscriptionClient)? = DesktopLiveTranscription.makeClient
        XCTAssertNotNil(original(GeminiTranscribeModels.liveCatalogID, "synthetic", nil, { _ in
            fatalError("Constructing a client does not connect")
        }))
    }
}
