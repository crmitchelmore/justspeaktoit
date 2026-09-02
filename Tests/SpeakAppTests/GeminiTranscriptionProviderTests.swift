// swiftlint:disable file_length
import Foundation
import XCTest

@testable import SpeakApp
@testable import SpeakCore

/// Catalogue, routing and Interactions API coverage for Gemini 3.5 Transcribe
/// (issue #816).
final class GeminiTranscriptionProviderTests: XCTestCase { // swiftlint:disable:this type_body_length

  // MARK: - Catalogue

  func testModelCatalogLiveTranscription_includesGeminiTranscribeLiveMarkedPreview() throws {
    let option = try XCTUnwrap(
      ModelCatalog.liveTranscription.first { $0.id == "google/gemini-3.5-transcribe-live" })

    XCTAssertEqual(option.displayName, "Gemini 3.5 Transcribe Live (Preview)")
    XCTAssertEqual(option.latencyTier, .fast)
    // The catalogue has no availability field, so preview status has to be
    // legible in the copy the picker shows.
    XCTAssertTrue(try XCTUnwrap(option.description).contains("Public preview"))
  }

  func testModelCatalogBatchTranscription_includesGeminiTranscribeMarkedPreview() throws {
    let option = try XCTUnwrap(
      ModelCatalog.batchTranscription.first { $0.id == "google/gemini-3.5-transcribe" })

    XCTAssertEqual(option.displayName, "Gemini 3.5 Transcribe (Google, Preview)")
    XCTAssertTrue(try XCTUnwrap(option.description).contains("Public preview"))
  }

  func testNeitherPreviewModelIsADefault() {
    XCTAssertNotEqual(ModelCatalog.defaultBatchTranscriptionModel, "google/gemini-3.5-transcribe")
    XCTAssertNotEqual(
      ModelCatalog.defaultOnDeviceLiveTranscriptionModel, "google/gemini-3.5-transcribe-live")
  }

  func testGeminiCapabilities_supportLivePolishAndPostStopFinalisation() {
    let capabilities = ModelCatalog.liveCapabilities(for: "google/gemini-3.5-transcribe-live")

    XCTAssertTrue(capabilities.supportedSpeedModes.contains(.instant))
    XCTAssertTrue(capabilities.supportedSpeedModes.contains(.livePolish))
    XCTAssertGreaterThan(capabilities.postStopFinalizeBudget, 0)
  }

  // MARK: - Registry and credentials

  func testProviderRegistry_routesGeminiBatchModelToTheGoogleProvider() async {
    let provider = await TranscriptionProviderRegistry.shared.provider(
      forModel: "google/gemini-3.5-transcribe")

    XCTAssertEqual(provider?.metadata.id, "google")
    XCTAssertEqual(provider?.metadata.apiKeyIdentifier, "google.apiKey")
  }

  /// The `google/` prefix is shared with the OpenRouter-routed Gemini 2.0
  /// entries; claiming them would break their existing OpenRouter path.
  func testProviderRegistry_leavesOpenRouterRoutedGeminiModelsAlone() async {
    let provider = await TranscriptionProviderRegistry.shared.provider(
      forModel: "google/gemini-2.0-flash-001")

    XCTAssertNil(provider)
  }

  func testProviderSupportedModels_returnsOnlyTheDirectGeminiBatchModel() {
    let provider = GeminiTranscriptionProvider()

    XCTAssertEqual(provider.supportedModels().map(\.id), ["google/gemini-3.5-transcribe"])
  }

  func testCredentialResolver_splitsDirectGeminiFromOpenRouterRoutedGemini() {
    XCTAssertEqual(
      ModelCredentialResolver.requirement(
        for: "google/gemini-3.5-transcribe", purpose: .batchTranscription),
      .apiKey(identifier: "google.apiKey", providerName: "Google Gemini")
    )
    XCTAssertEqual(
      ModelCredentialResolver.requirement(
        for: "google/gemini-2.0-flash-001", purpose: .batchTranscription),
      .apiKey(identifier: "openrouter.apiKey", providerName: "OpenRouter")
    )
    XCTAssertEqual(
      ModelCredentialResolver.requirement(
        for: "google/gemini-3.5-transcribe-live", purpose: .liveTranscription),
      .apiKey(identifier: "google.apiKey", providerName: "Google Gemini")
    )
  }

  // MARK: - Interactions request

  func testInteractionsRequest_usesDocumentedEndpointHeaderAndInlineAudio() throws {
    // Arrange
    let audio = Data([0x00, 0x01, 0x02, 0x03])

    // Act
    let request = try GeminiInteractionsRequest.make(
      apiKey: "gemini-test-key",
      audio: .inline(audio),
      mimeType: "audio/m4a",
      language: "en_GB"
    )
    let body = try XCTUnwrap(request.httpBody)
    let payload = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: body) as? [String: Any])
    let input = try XCTUnwrap(payload["input"] as? [[String: Any]])
    let generation = try XCTUnwrap(payload["generation_config"] as? [String: Any])
    let config = try XCTUnwrap(generation["transcription_config"] as? [String: Any])
    let mode = try XCTUnwrap(config["mode"] as? [String: Any])

    // Assert
    XCTAssertEqual(
      request.url?.absoluteString,
      "https://generativelanguage.googleapis.com/v1beta/interactions")
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "gemini-test-key")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    XCTAssertEqual(payload["model"] as? String, "gemini-3.5-transcribe")
    XCTAssertEqual(input.first?["type"] as? String, "audio")
    XCTAssertEqual(input.first?["mime_type"] as? String, "audio/m4a")
    XCTAssertEqual(input.first?["data"] as? String, audio.base64EncodedString())
    XCTAssertNil(input.first?["uri"])
    XCTAssertEqual(config["language_codes"] as? [String], ["en-GB"])
    XCTAssertEqual(mode["type"] as? String, "verbatim")
    XCTAssertEqual(mode["timestamp_granularities"] as? [String], ["word"])
    XCTAssertEqual(mode["diarization_mode"] as? String, "speaker")
  }

  func testInteractionsRequest_referencesAnUploadedFileWhenTheAudioIsLarge() throws {
    let request = try GeminiInteractionsRequest.make(
      apiKey: "k",
      audio: .fileURI("https://generativelanguage.googleapis.com/v1beta/files/abc123"),
      mimeType: "audio/wav",
      language: nil
    )
    let payload = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
    let input = try XCTUnwrap(payload["input"] as? [[String: Any]])
    let generation = try XCTUnwrap(payload["generation_config"] as? [String: Any])
    let config = try XCTUnwrap(generation["transcription_config"] as? [String: Any])

    XCTAssertEqual(
      input.first?["uri"] as? String,
      "https://generativelanguage.googleapis.com/v1beta/files/abc123")
    XCTAssertNil(input.first?["data"])
    // An empty array is the documented "detect the language automatically" setting.
    XCTAssertEqual(config["language_codes"] as? [String], [])
  }

  func testInteractionsRequest_smartModeDropsAnnotationsItCannotCombineWith() throws {
    let request = try GeminiInteractionsRequest.make(
      apiKey: "k", audio: .inline(Data()), mimeType: "audio/m4a", language: nil, mode: .smart)
    let payload = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
    let generation = try XCTUnwrap(payload["generation_config"] as? [String: Any])
    let config = try XCTUnwrap(generation["transcription_config"] as? [String: Any])

    XCTAssertEqual(config["mode"] as? String, "smart")
  }

  // MARK: - Response parsing

  func testResponseParsing_readsTranscriptWordTimingsAndSpeakerLabels() throws {
    let json = """
    {
      "id": "interactions/abc123xyz",
      "status": "completed",
      "output_text": "Hello world",
      "steps": [
        {
          "id": "step_001",
          "type": "model_output",
          "content": [
            {
              "type": "text",
              "text": "Hello world",
              "annotations": [
                {
                  "type": "word_info",
                  "text": "Hello",
                  "speaker": "spk_1",
                  "start_offset": "0.100s",
                  "end_offset": "0.450s"
                },
                {
                  "type": "word_info",
                  "text": "world",
                  "speaker": "spk_2",
                  "start_offset": "0.460s",
                  "end_offset": "0.900s"
                }
              ]
            }
          ]
        }
      ]
    }
    """

    let decoded = try JSONDecoder().decode(
      GeminiInteractionsResponse.self, from: Data(json.utf8))

    XCTAssertEqual(decoded.transcript, "Hello world")
    XCTAssertEqual(
      decoded.wordAnnotations,
      [
        GeminiWordAnnotation(text: "Hello", speaker: "spk_1", startTime: 0.1, endTime: 0.45),
        GeminiWordAnnotation(text: "world", speaker: "spk_2", startTime: 0.46, endTime: 0.9)
      ]
    )
  }

  func testResponseParsing_fallsBackToStepTextWhenOutputTextIsAbsent() throws {
    let json = """
    {"status":"completed","steps":[{"type":"model_output","content":[
      {"type":"text","text":"First part."},{"type":"text","text":"Second part."}]}]}
    """

    let decoded = try JSONDecoder().decode(
      GeminiInteractionsResponse.self, from: Data(json.utf8))

    XCTAssertEqual(decoded.transcript, "First part. Second part.")
    XCTAssertTrue(decoded.wordAnnotations.isEmpty)
  }

  func testResponseParsing_ignoresNonWordAnnotationsAndMalformedOffsets() throws {
    let json = """
    {"output_text":"Hi","steps":[{"content":[{"annotations":[
      {"type":"citation","text":"nope"},
      {"type":"word_info","text":"Hi","start_offset":"oops","end_offset":null}]}]}]}
    """

    let decoded = try JSONDecoder().decode(
      GeminiInteractionsResponse.self, from: Data(json.utf8))

    XCTAssertEqual(
      decoded.wordAnnotations,
      [GeminiWordAnnotation(text: "Hi", speaker: nil, startTime: 0, endTime: 0)]
    )
  }

  func testResponseParsing_offsetSecondsAcceptsBothSpellings() {
    XCTAssertEqual(GeminiInteractionsResponse.seconds(from: "1.250s"), 1.25)
    XCTAssertEqual(GeminiInteractionsResponse.seconds(from: "2"), 2)
    XCTAssertEqual(GeminiInteractionsResponse.seconds(from: nil), 0)
  }

  // MARK: - HTTP error mapping

  func testHTTPFailure_mapsAuthRateLimitAndOtherStatuses() {
    let authBody = Data(
      #"{"error":{"code":403,"message":"denied","status":"PERMISSION_DENIED"}}"#.utf8)
    // `StreamingClientError` is a LocalizedError the UI renders, not an
    // Equatable value, so the assertion matches the case.
    guard case StreamingClientError.invalidAPIKey(let provider) =
      GeminiInteractionsResponse.mapHTTPFailure(status: 403, body: authBody) else {
      return XCTFail("Expected invalidAPIKey")
    }
    XCTAssertEqual(provider, "Google Gemini")

    let rateBody = Data(#"{"error":{"code":429,"message":"slow down"}}"#.utf8)
    XCTAssertEqual(
      GeminiInteractionsResponse.mapHTTPFailure(status: 429, body: rateBody) as? GeminiBatchError,
      .rateLimited("slow down")
    )

    let serverBody = Data(#"{"error":{"code":503,"message":"overloaded"}}"#.utf8)
    guard case TranscriptionProviderError.httpError(let code, let message) =
      GeminiInteractionsResponse.mapHTTPFailure(status: 503, body: serverBody) else {
      return XCTFail("Expected an httpError")
    }
    XCTAssertEqual(code, 503)
    XCTAssertEqual(message, "overloaded")
  }

  func testHTTPFailure_keepsTheRawBodyWhenItIsNotAGeminiEnvelope() {
    guard case TranscriptionProviderError.httpError(_, let message) =
      GeminiInteractionsResponse.mapHTTPFailure(status: 500, body: Data("upstream down".utf8)) else {
      return XCTFail("Expected an httpError")
    }

    XCTAssertEqual(message, "upstream down")
  }

  func testMIMEType_isDerivedFromTheRecordingExtension() {
    XCTAssertEqual(GeminiAudioMIMEType.forFile(at: URL(fileURLWithPath: "/tmp/a.wav")), "audio/wav")
    XCTAssertEqual(GeminiAudioMIMEType.forFile(at: URL(fileURLWithPath: "/tmp/a.M4A")), "audio/m4a")
    XCTAssertEqual(GeminiAudioMIMEType.forFile(at: URL(fileURLWithPath: "/tmp/a.bin")), "audio/m4a")
  }

  // MARK: - Credential validation

  func testValidateAPIKey_probesListModelsAndRedactsTheKeyInDebugHeaders() async throws {
    let observer = GeminiRequestObserver()
    GeminiMockURLProtocol.requestHandler = { request in
      await observer.store(request: request)
      let response = HTTPURLResponse(
        url: try XCTUnwrap(request.url),
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (response, Data(#"{"models":[{"name":"models/gemini-3.5-transcribe"}]}"#.utf8))
    }
    defer { GeminiMockURLProtocol.requestHandler = nil }

    let provider = GeminiTranscriptionProvider(session: makeMockSession())
    let result = await provider.validateAPIKey("gemini-test-key")

    let capturedRequest = await observer.capturedRequest()
    let captured = try XCTUnwrap(capturedRequest)
    XCTAssertEqual(captured.url?.path, "/v1beta/models")
    XCTAssertEqual(captured.httpMethod, "GET")
    XCTAssertEqual(captured.value(forHTTPHeaderField: "x-goog-api-key"), "gemini-test-key")
    if case .success = result.outcome {
      // pass
    } else {
      XCTFail("Expected validation success")
    }
    XCTAssertEqual(result.debug?.requestHeaders["x-goog-api-key"], "[REDACTED]")
  }

  func testValidateAPIKey_returnsFailureOnUnauthorized() async {
    GeminiMockURLProtocol.requestHandler = { request in
      let response = HTTPURLResponse(
        url: try XCTUnwrap(request.url),
        statusCode: 401,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (response, Data(#"{"error":{"code":401,"message":"API key not valid"}}"#.utf8))
    }
    defer { GeminiMockURLProtocol.requestHandler = nil }

    let provider = GeminiTranscriptionProvider(session: makeMockSession())
    let result = await provider.validateAPIKey("bad-key")

    if case .failure(let message) = result.outcome {
      XCTAssertTrue(message.contains("401"))
    } else {
      XCTFail("Expected validation failure")
    }
  }

  func testValidateAPIKey_reportsRateLimitsSeparately() async {
    GeminiMockURLProtocol.requestHandler = { request in
      let response = HTTPURLResponse(
        url: try XCTUnwrap(request.url), statusCode: 429, httpVersion: nil, headerFields: nil)!
      return (response, Data(#"{"error":{"code":429,"message":"quota"}}"#.utf8))
    }
    defer { GeminiMockURLProtocol.requestHandler = nil }

    let provider = GeminiTranscriptionProvider(session: makeMockSession())
    let result = await provider.validateAPIKey("k")

    if case .failure(let message) = result.outcome {
      XCTAssertTrue(message.contains("rate limit"))
    } else {
      XCTFail("Expected validation failure")
    }
  }

  func testValidateAPIKey_rejectsABlankKeyWithoutARequest() async {
    let provider = GeminiTranscriptionProvider(session: makeMockSession())

    let result = await provider.validateAPIKey("   ")

    if case .failure(let message) = result.outcome {
      XCTAssertEqual(message, "Empty API key")
    } else {
      XCTFail("Expected validation failure")
    }
  }

  // MARK: - transcribeFile guards

  func testTranscribeFile_rejectsAModelThisProviderDoesNotOwn() async {
    let provider = GeminiTranscriptionProvider(session: makeMockSession())

    do {
      _ = try await provider.transcribeFile(
        at: URL(fileURLWithPath: "/tmp/does-not-matter.m4a"),
        apiKey: "k",
        model: "google/gemini-2.0-flash-001",
        language: nil
      )
      XCTFail("Expected an unsupportedModel error")
    } catch {
      XCTAssertEqual(error as? GeminiBatchError, .unsupportedModel("google/gemini-2.0-flash-001"))
    }
  }

  func testTranscribeFile_rejectsABlankAPIKeyBeforeTouchingTheDisk() async {
    let provider = GeminiTranscriptionProvider(session: makeMockSession())

    do {
      _ = try await provider.transcribeFile(
        at: URL(fileURLWithPath: "/tmp/missing.m4a"),
        apiKey: "  ",
        model: "google/gemini-3.5-transcribe",
        language: nil
      )
      XCTFail("Expected a missingAPIKey error")
    } catch {
      XCTAssertEqual(error as? GeminiBatchError, .missingAPIKey)
    }
  }

  private func makeMockSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [GeminiMockURLProtocol.self]
    return URLSession(configuration: configuration)
  }
}

private actor GeminiRequestObserver {
  private var request: URLRequest?

  func store(request: URLRequest) {
    self.request = request
  }

  func capturedRequest() -> URLRequest? {
    request
  }
}

private final class GeminiMockURLProtocol: URLProtocol {
  #if compiler(>=5.10)
    nonisolated(unsafe) static var requestHandler:
      (@Sendable (URLRequest) async throws -> (HTTPURLResponse, Data))?
  #else
    static var requestHandler: (@Sendable (URLRequest) async throws -> (HTTPURLResponse, Data))?
  #endif

  override static func canInit(with request: URLRequest) -> Bool {
    true
  }

  override static func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    guard let handler = Self.requestHandler else {
      XCTFail("GeminiMockURLProtocol.requestHandler was not set")
      return
    }

    Task {
      do {
        let (response, data) = try await handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
      } catch {
        client?.urlProtocol(self, didFailWithError: error)
      }
    }
  }

  override func stopLoading() {}
}
