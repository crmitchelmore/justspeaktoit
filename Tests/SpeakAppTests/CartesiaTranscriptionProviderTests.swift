import Foundation
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
    CartesiaMockURLProtocol.requestHandler = { request in
      let response = HTTPURLResponse(
        url: try XCTUnwrap(request.url),
        statusCode: 401,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (response, Data(#"{"error":"unauthorized"}"#.utf8))
    }
    defer { CartesiaMockURLProtocol.requestHandler = nil }

    let provider = CartesiaTranscriptionProvider(session: makeMockSession())
    let result = await provider.validateAPIKey("secret-cartesia-key")

    let authorization = try XCTUnwrap(result.debug?.requestHeaders["Authorization"])
    XCTAssertTrue(authorization.contains("RE"))
    XCTAssertFalse(authorization.contains("secret-cartesia-key"))
  }

  private func makeMockSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CartesiaMockURLProtocol.self]
    return URLSession(configuration: configuration)
  }
}

private final class CartesiaMockURLProtocol: URLProtocol {
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
      XCTFail("CartesiaMockURLProtocol.requestHandler was not set")
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
