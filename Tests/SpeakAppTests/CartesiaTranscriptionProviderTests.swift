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

  /// The macOS controller opens the one canonical handshake the shared client
  /// opens: the trimmed key as a bearer token and the pinned version.
  func testLiveRequest_isTheCanonicalSharedRequest() throws {
    let request = try XCTUnwrap(CartesiaLiveTranscriber.webSocketRequest(
      apiKey: " synthetic-key \n", model: "ink-2", sampleRate: 16_000
    ))
    let canonical = try XCTUnwrap(CartesiaLiveClient.webSocketRequest(
      apiKey: "synthetic-key", model: "ink-2", sampleRate: 16_000
    ))

    XCTAssertEqual(request.url, canonical.url)
    XCTAssertEqual(
      request.url?.absoluteString,
      "wss://api.cartesia.ai/stt/turns/websocket?model=ink-2&encoding=pcm_s16le&sample_rate=16000"
        + "&cartesia_version=2026-03-01"
    )
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-key")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Cartesia-Version"), "2026-03-01")
    XCTAssertEqual(request.allHTTPHeaderFields, canonical.allHTTPHeaderFields)
    XCTAssertEqual(CartesiaLiveTranscriber.apiVersion, CartesiaLiveClient.apiVersion)
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
    StubURLProtocol.respond {  request in
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

  private func makeMockSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: configuration)
  }
}
