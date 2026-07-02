import Foundation
import XCTest

@testable import SpeakApp
@testable import SpeakCore

final class GladiaTranscriptionProviderTests: XCTestCase {
  func testModelCatalogLiveTranscription_includesGladiaSolariaStreaming() throws {
    let option = try XCTUnwrap(ModelCatalog.liveTranscription.first { $0.id == "gladia/solaria-1-streaming" })

    XCTAssertEqual(option.displayName, "Gladia Solaria-1 (Streaming)")
    XCTAssertEqual(option.latencyTier, .fast)
  }

  func testGladiaCapabilities_supportLivePolishAndPostStopFinalisation() {
    let capabilities = ModelCatalog.liveCapabilities(for: "gladia/solaria-1-streaming")

    XCTAssertTrue(capabilities.supportedSpeedModes.contains(.instant))
    XCTAssertTrue(capabilities.supportedSpeedModes.contains(.livePolish))
    XCTAssertGreaterThan(capabilities.postStopFinalizeBudget, 0)
  }

  func testProviderRegistry_routesGladiaModelToGladiaProvider() async {
    let provider = await TranscriptionProviderRegistry.shared.provider(forModel: "gladia/solaria-1-streaming")

    XCTAssertEqual(provider?.metadata.id, "gladia")
    XCTAssertEqual(provider?.metadata.apiKeyIdentifier, "gladia.apiKey")
  }

  func testProviderSupportedModels_returnsLiveSolariaModel() {
    let provider = GladiaTranscriptionProvider()
    let ids = provider.supportedModels().map(\.id)

    XCTAssertEqual(ids, ["gladia/solaria-1-streaming"])
  }

  func testInitRequest_usesDocumentedEndpointHeadersAndPCM16Config() throws {
    let request = try GladiaLiveTranscriber.makeInitRequest(
      apiKey: "test-gladia-key",
      model: "gladia/solaria-1-streaming",
      language: "en_GB",
      sampleRate: 16_000
    )
    let body = try XCTUnwrap(request.httpBody)
    let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
    let payload = try XCTUnwrap(json)
    let languageConfig = try XCTUnwrap(payload["language_config"] as? [String: Any])
    let messagesConfig = try XCTUnwrap(payload["messages_config"] as? [String: Any])

    XCTAssertEqual(request.url?.absoluteString, "https://api.gladia.io/v2/live")
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.value(forHTTPHeaderField: "x-gladia-key"), "test-gladia-key")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    XCTAssertEqual(payload["model"] as? String, "solaria-1")
    XCTAssertEqual(payload["encoding"] as? String, "wav/pcm")
    XCTAssertEqual(payload["bit_depth"] as? Int, 16)
    XCTAssertEqual(payload["sample_rate"] as? Int, 16_000)
    XCTAssertEqual(payload["channels"] as? Int, 1)
    XCTAssertEqual(languageConfig["languages"] as? [String], [])
    XCTAssertEqual(languageConfig["code_switching"] as? Bool, true)
    XCTAssertEqual(messagesConfig["receive_partial_transcripts"] as? Bool, true)
    XCTAssertEqual(messagesConfig["receive_final_transcripts"] as? Bool, true)
  }

  func testStopRecordingMessage_usesDocumentedShape() {
    XCTAssertEqual(GladiaLiveTranscriber.stopRecordingMessage(), #"{"type":"stop_recording"}"#)
  }

  func testTranscriptEvent_parsesPartialTranscript() {
    let json = """
    {
      "session_id": "550e8400-e29b-41d4-a716-446655440000",
      "created_at": "2025-09-19T12:34:10Z",
      "type": "transcript",
      "data": {
        "id": "00-00000011",
        "is_final": false,
        "utterance": {
          "text": "Hello wor",
          "confidence": 0.91,
          "language": "en"
        }
      }
    }
    """

    let event = GladiaLiveTranscriber.transcriptEvent(from: json)

    XCTAssertEqual(event?.text, "Hello wor")
    XCTAssertEqual(event?.isFinal, false)
    XCTAssertEqual(event?.confidence, 0.91)
  }

  func testTranscriptEvent_parsesFinalTranscript() {
    let json = """
    {
      "type": "transcript",
      "data": {
        "id": "00-00000011",
        "is_final": true,
        "utterance": {"text": "Hello world.", "confidence": 0.98}
      }
    }
    """

    let event = GladiaLiveTranscriber.transcriptEvent(from: json)

    XCTAssertEqual(event?.text, "Hello world.")
    XCTAssertEqual(event?.isFinal, true)
    XCTAssertEqual(event?.confidence, 0.98)
  }

  func testTranscriptEvent_ignoresNonTranscriptAndEmptyText() {
    XCTAssertNil(GladiaLiveTranscriber.transcriptEvent(from: #"{"type":"speech_start","data":{}}"#))
    XCTAssertNil(GladiaLiveTranscriber.transcriptEvent(
      from: #"{"type":"transcript","data":{"is_final":true,"utterance":{"text":""}}}"#
    ))
  }

  func testValidateAPIKey_sendsXGladiaKeyAndRedactsDebugHeaders() async throws {
    let observer = GladiaRequestObserver()
    GladiaMockURLProtocol.requestHandler = { request in
      await observer.store(request: request)
      let response = HTTPURLResponse(
        url: try XCTUnwrap(request.url),
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      let body = #"{"items":[{"status":"done","result":{"transcription":"private prior transcript"}}]}"#
      return (response, Data(body.utf8))
    }
    defer { GladiaMockURLProtocol.requestHandler = nil }

    let provider = GladiaTranscriptionProvider(session: makeMockSession())
    let result = await provider.validateAPIKey("gladia-test-key")

    let capturedRequest = await observer.capturedRequest()
    let captured = try XCTUnwrap(capturedRequest)
    XCTAssertEqual(captured.url?.path, "/v2/live")
    XCTAssertEqual(captured.httpMethod, "GET")
    XCTAssertEqual(captured.value(forHTTPHeaderField: "x-gladia-key"), "gladia-test-key")
    if case .success = result.outcome {
      // pass
    } else {
      XCTFail("Expected validation success")
    }
    XCTAssertEqual(result.debug?.requestHeaders["x-gladia-key"], "gla...-key")
    XCTAssertNil(result.debug?.responseBody)
  }

  func testValidateAPIKey_returnsFailureOnUnauthorized() async {
    GladiaMockURLProtocol.requestHandler = { request in
      let response = HTTPURLResponse(
        url: try XCTUnwrap(request.url),
        statusCode: 401,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (response, Data(#"{"message":"invalid key"}"#.utf8))
    }
    defer { GladiaMockURLProtocol.requestHandler = nil }

    let provider = GladiaTranscriptionProvider(session: makeMockSession())
    let result = await provider.validateAPIKey("bad-key")

    if case .failure(let message) = result.outcome {
      XCTAssertTrue(message.contains("401"))
    } else {
      XCTFail("Expected validation failure")
    }
    XCTAssertEqual(result.debug?.responseBody, #"{"message":"invalid key"}"#)
  }

  private func makeMockSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [GladiaMockURLProtocol.self]
    return URLSession(configuration: configuration)
  }
}

private actor GladiaRequestObserver {
  private var request: URLRequest?

  func store(request: URLRequest) {
    self.request = request
  }

  func capturedRequest() -> URLRequest? {
    request
  }
}

private final class GladiaMockURLProtocol: URLProtocol {
#if compiler(>=5.10)
  nonisolated(unsafe) static var requestHandler: (@Sendable (URLRequest) async throws -> (HTTPURLResponse, Data))?
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
      XCTFail("GladiaMockURLProtocol.requestHandler was not set")
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
