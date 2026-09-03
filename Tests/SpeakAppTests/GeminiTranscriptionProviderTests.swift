import Foundation
import XCTest

@testable import SpeakApp
@testable import SpeakCore

/// Catalogue, routing and credential coverage for Gemini 3.5 Transcribe
/// (issue #816).
///
/// The Interactions API client itself now lives in SpeakCore so iOS shares it
/// (issue #862); its request shaping, ACTIVE-state poll and error mapping are
/// covered by `GeminiInteractionsClientTests`. What is asserted here is the
/// macOS provider wrapper: registry metadata, credential validation, the
/// catalogue filter, and that transcription really does reach the shared
/// client.
final class GeminiTranscriptionProviderTests: XCTestCase {

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

  // MARK: - Delegation to the shared client

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

  /// The provider is a wrapper now, so the assertion that matters is that a
  /// transcription really does go out over the Interactions API with the word
  /// annotations preserved as segments.
  func testTranscribeFile_reachesTheSharedInteractionsClient() async throws {
    let audioURL = try Self.makeTemporaryAudioFile()
    defer { try? FileManager.default.removeItem(at: audioURL) }

    GeminiMockURLProtocol.requestHandler = { request in
      let url = try XCTUnwrap(request.url)
      XCTAssertEqual(url.path, "/v1beta/interactions")
      let response = HTTPURLResponse(
        url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
      let body = """
      {"output_text":"Hello world","steps":[{"type":"model_output","content":[
        {"type":"text","text":"Hello world","annotations":[
          {"type":"word_info","text":"Hello","speaker":"spk_1","start_offset":"0.100s","end_offset":"0.450s"},
          {"type":"word_info","text":"world","speaker":"spk_2","start_offset":"0.460s","end_offset":"0.900s"}
        ]}]}]}
      """
      return (response, Data(body.utf8))
    }
    defer { GeminiMockURLProtocol.requestHandler = nil }

    let provider = GeminiTranscriptionProvider(session: makeMockSession())
    let result = try await provider.transcribeFile(
      at: audioURL, apiKey: "k", model: "google/gemini-3.5-transcribe", language: nil)

    XCTAssertEqual(result.text, "Hello world")
    XCTAssertEqual(result.segments.map(\.text), ["Hello", "world"])
    XCTAssertTrue(try XCTUnwrap(result.rawPayload).contains("spk_2"))
  }

  private static func makeTemporaryAudioFile() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("gemini-\(UUID().uuidString).m4a")
    try Data([0x00, 0x01, 0x02, 0x03]).write(to: url, options: .atomic)
    return url
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
