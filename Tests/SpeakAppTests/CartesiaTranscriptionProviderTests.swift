import Foundation
import SpeakTestSupport
import XCTest

@testable import SpeakApp
@testable import SpeakCore

final class CartesiaTranscriptionProviderTests: XCTestCase {
  func testModelCatalogLiveTranscription_includesInk2() {
    let ids = ModelCatalog.liveTranscription.map(\.id)

    XCTAssertTrue(ids.contains("cartesia/ink-2-streaming"))
  }

  func testInk2SupportsLivePolish() {
    let capabilities = ModelCatalog.liveCapabilities(for: "cartesia/ink-2-streaming")

    XCTAssertTrue(capabilities.supportedSpeedModes.contains(.livePolish))
    XCTAssertEqual(capabilities.postStopFinalizeBudget, 1.5)
  }

  func testProviderRegistry_routesCartesiaModelToCartesiaProvider() async {
    let provider = await TranscriptionProviderRegistry.shared.provider(forModel: "cartesia/ink-2-streaming")

    XCTAssertEqual(provider?.metadata.id, "cartesia")
  }

  func testWebSocketURL_usesTurnsEndpointAndInk2Parameters() throws {
    let url = try XCTUnwrap(CartesiaLiveTranscriber.webSocketURL(model: "ink-2", sampleRate: 16_000))
    let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let query = Dictionary(uniqueKeysWithValues: try XCTUnwrap(components.queryItems).map { ($0.name, $0.value ?? "") })

    XCTAssertEqual(components.scheme, "wss")
    XCTAssertEqual(components.host, "api.cartesia.ai")
    XCTAssertEqual(components.path, "/stt/turns/websocket")
    XCTAssertEqual(query["model"], "ink-2")
    XCTAssertEqual(query["encoding"], "pcm_s16le")
    XCTAssertEqual(query["sample_rate"], "16000")
    XCTAssertEqual(query["cartesia_version"], CartesiaLiveTranscriber.apiVersion)
  }

  func testTranscriptEvent_turnUpdateProducesPartial() {
    let json = """
    {"type":"turn.update","results":[{"transcript":"book a table"}]}
    """

    let event = CartesiaLiveTranscriber.transcriptEvent(from: json)

    XCTAssertEqual(event?.text, "book a table")
    XCTAssertEqual(event?.isFinal, false)
  }

  func testTranscriptEvent_turnEndProducesFinal() {
    let json = """
    {"type":"turn.end","results":[{"transcript":"book a table for two"}]}
    """

    let event = CartesiaLiveTranscriber.transcriptEvent(from: json)

    XCTAssertEqual(event?.text, "book a table for two")
    XCTAssertEqual(event?.isFinal, true)
  }

  func testTranscriptEvent_ignoresEmptyTranscript() {
    let json = #"{"type":"turn.update","results":[{"transcript":""}]}"#

    XCTAssertNil(CartesiaLiveTranscriber.transcriptEvent(from: json))
  }

  func testValidateAPIKey_redactsAuthorizationHeaderInDebugSnapshot() async throws {
    StubURLProtocol.respond { request in
      XCTAssertEqual(request.httpMethod, "GET")
      XCTAssertEqual(request.url?.path, "/voices")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-cartesia-key")
      XCTAssertEqual(
        request.value(forHTTPHeaderField: "Cartesia-Version"), CartesiaLiveClient.apiVersion
      )
      let response = HTTPURLResponse(
        url: try XCTUnwrap(request.url),
        statusCode: 401,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (response, Data(#"{"error":"unauthorized"}"#.utf8))
    }
    defer { StubURLProtocol.reset() }

    let provider = CartesiaTranscriptionProvider(session: makeMockSession())
    let result = await provider.validateAPIKey("secret-cartesia-key")

    let authorization = try XCTUnwrap(result.debug?.requestHeaders["Authorization"])
    XCTAssertTrue(authorization.contains("RE"))
    XCTAssertFalse(authorization.contains("secret-cartesia-key"))
  }

  func testValidateAPIKey_trimsKeyAndAcceptsSuccess() async throws {
    StubURLProtocol.respond { request in
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer trimmed-key")
      let response = HTTPURLResponse(
        url: try XCTUnwrap(request.url), statusCode: 200,
        httpVersion: nil, headerFields: nil
      )!
      return (response, Data())
    }
    defer { StubURLProtocol.reset() }

    let result = await CartesiaTranscriptionProvider(session: makeMockSession())
      .validateAPIKey("  trimmed-key\n")

    if case .failure(let message) = result.outcome {
      XCTFail("Expected successful validation, got \(message)")
    }
  }

  func testValidateAPIKey_emptyKeyDoesNotCreateRequest() async {
    StubURLProtocol.reset()
    StubURLProtocol.respond { request in
      XCTFail("Empty key unexpectedly created request: \(request)")
      throw URLError(.badURL)
    }
    defer { StubURLProtocol.reset() }

    let result = await CartesiaTranscriptionProvider(session: makeMockSession())
      .validateAPIKey(" \n ")

    XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)

    if case .failure(let message) = result.outcome {
      XCTAssertEqual(message, "Empty API key")
    } else {
      XCTFail("Expected empty key failure")
    }
  }

  func testValidateAPIKey_reportsBothCredentialRejectionStatuses() async throws {
    defer { StubURLProtocol.reset() }
    for status in [401, 403] {
      let expectedStatus = status
      StubURLProtocol.respond { request in
        let response = HTTPURLResponse(
          url: try XCTUnwrap(request.url), statusCode: expectedStatus,
          httpVersion: nil, headerFields: nil
        )!
        return (response, Data())
      }
      let result = await CartesiaTranscriptionProvider(session: makeMockSession())
        .validateAPIKey("key")
      if case .failure(let message) = result.outcome {
        XCTAssertTrue(message.contains(String(expectedStatus)))
      } else {
        XCTFail("Expected HTTP \(expectedStatus) to reject the credential")
      }
    }
  }

  private func makeMockSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: configuration)
  }
}
