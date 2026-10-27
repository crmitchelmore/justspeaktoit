import Foundation
import SpeakTestSupport
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

  func testProviderSupportedModels_returnsLiveAndBatchSolariaModels() {
    let provider = GladiaTranscriptionProvider()
    let ids = provider.supportedModels().map(\.id)

    XCTAssertEqual(ids, ["gladia/solaria-1-streaming", GladiaBatchClient.catalogID])
  }

  func testValidateAPIKey_sendsXGladiaKeyAndRedactsDebugHeaders() async throws {
    let observer = GladiaRequestObserver()
    StubURLProtocol.respond {  request in
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
    defer { StubURLProtocol.reset() }

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
    XCTAssertEqual(result.debug?.requestHeaders["x-gladia-key"], "[REDACTED]")
    XCTAssertNil(result.debug?.responseBody)
  }

  func testValidateAPIKey_returnsFailureOnUnauthorized() async {
    StubURLProtocol.respond {  request in
      let response = HTTPURLResponse(
        url: try XCTUnwrap(request.url),
        statusCode: 401,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (response, Data(#"{"message":"invalid key"}"#.utf8))
    }
    defer { StubURLProtocol.reset() }

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
    configuration.protocolClasses = [StubURLProtocol.self]
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
