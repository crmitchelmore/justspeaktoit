import XCTest
@testable import SpeakCore

final class OpenRouterAudioModelTests: XCTestCase {
    func testDiscovery_ExcludesAudioChatAndKeepsDedicatedEndpoints() throws {
        let response = try decode("""
        {"data":[
          {"id":"vendor/chat","architecture":{"input_modalities":["audio"],"output_modalities":["text","audio"]}},
          {"id":"vendor/stt","architecture":{"input_modalities":["audio"],"output_modalities":["transcription"]}},
          {"id":"vendor/tts","architecture":{"input_modalities":["text"],"output_modalities":["speech"]}},
          {"id":"vendor/future","architecture":{"input_modalities":["text"],"output_modalities":["future"]}}
        ]}
        """)

        XCTAssertEqual(response.data.map(\.id), ["vendor/stt", "vendor/tts"])
        XCTAssertEqual(response.data.map(\.capability), [.transcription, .speech])
        XCTAssertEqual(response.data[0].transcriptionSelectionID, "openrouter/transcription/vendor/stt")
    }

    func testMetadata_PreservesUnknownUnitsAndModelSpecificVoices() throws {
        let model = try XCTUnwrap(try decode("""
        {"data":[{
          "id":"vendor/tts", "name":"Example speech", "description":"Provider description",
          "architecture":{"input_modalities":["text"],"output_modalities":["speech"]},
          "pricing":{"prompt":"0.000000125","future_audio_second":"0.001","malformed_price":{}},
          "supported_parameters":["voice","future_control"], "supported_voices":["custom/voice-one"],
          "context_length":4096, "expiration_date":"2027-01-01", "future_metadata":{"safe":true}
        }]}
        """).data.first)

        XCTAssertEqual(model.pricing, ["prompt": "0.000000125", "future_audio_second": "0.001"])
        XCTAssertEqual(model.supportedVoices, ["custom/voice-one"])
        XCTAssertEqual(model.supportedParameters, ["voice", "future_control"])
        XCTAssertEqual(model.contextLength, 4096)
        XCTAssertEqual(model.expirationDate, "2027-01-01")
        XCTAssertEqual(try JSONDecoder().decode(OpenRouterAudioModel.self, from: JSONEncoder().encode(model)), model)
    }

    func testMalformedEntriesAndDuplicateIDs_DoNotHideValidModels() throws {
        let models = try decode("""
        {"data":[null, 42, {"id":""}, {"id":12},
          {"id":"vendor/stt","architecture":{"input_modalities":["audio"],"output_modalities":["transcription"]},
           "name":false,"supported_voices":null,"pricing":null,"context_length":0},
          {"id":"vendor/stt","architecture":{"input_modalities":["audio"],"output_modalities":["transcription"]}}
        ]}
        """).data

        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models.first?.name, "vendor/stt")
        XCTAssertEqual(models.first?.supportedVoices, [])
        XCTAssertEqual(models.first?.pricing, [:])
        XCTAssertNil(models.first?.contextLength)
    }

    func testMalformedEnvelope_ThrowsButEmptyCatalogIsValid() throws {
        XCTAssertThrowsError(try decode(#"{"error":"unavailable"}"#))
        XCTAssertThrowsError(try decode(#"{"data":[null,{"id":false}]}"#))
        XCTAssertThrowsError(try decode("""
        {"data":[{"id":"vendor/chat","architecture":{"input_modalities":["audio"],"output_modalities":["text"]}}]}
        """))
        XCTAssertTrue(try decode(#"{"data":[]}"#).data.isEmpty)
    }

    func testMultiCapabilityModel_AppearsInBothProjections() throws {
        let model = try XCTUnwrap(try decode("""
        {"data":[{"id":"vendor/both","architecture":{
          "input_modalities":["audio","text"],"output_modalities":["speech","transcription"]
        }}]}
        """).data.first)

        XCTAssertTrue(model.supports(.transcription))
        XCTAssertTrue(model.supports(.speech))
    }

    func testUnavailableDynamicSelection_IsPreservedAndUsesOpenRouterCredential() {
        let selected = "openrouter/transcription/future-vendor/retired-model"

        XCTAssertEqual(ModelCatalog.normalizedBatchTranscriptionModel(selected), selected)
        XCTAssertEqual(
            ModelCredentialResolver.requirement(for: selected, purpose: .batchTranscription),
            .apiKey(identifier: "openrouter.apiKey", providerName: "OpenRouter")
        )
        XCTAssertEqual(
            ModelCredentialResolver.requirement(for: "openrouter/speech/saved-selection", purpose: .voiceOutput),
            .apiKey(identifier: "openrouter.apiKey", providerName: "OpenRouter")
        )
    }

    func testTranscriptionSelection_RejectsMalformedIDsAndPreservesProviderSlug() {
        let rawID = "provider/model-version:free"
        let identifier = OpenRouterTranscriptionSelection.identifier(for: rawID)
        XCTAssertEqual(OpenRouterTranscriptionSelection.modelID(from: identifier), rawID)
        for invalid in ["provider/model", "openrouter/transcription/", "openrouter/transcription/model",
                        "openrouter/transcription//model", "openrouter/transcription/provider/model\n"] {
            XCTAssertNil(OpenRouterTranscriptionSelection.modelID(from: invalid))
        }
    }

    private func decode(_ json: String) throws -> OpenRouterAudioModelResponse {
        try JSONDecoder().decode(OpenRouterAudioModelResponse.self, from: Data(json.utf8))
    }
}
