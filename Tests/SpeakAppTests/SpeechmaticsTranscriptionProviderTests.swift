import Foundation
import XCTest

@testable import SpeakApp
@testable import SpeakCore

final class SpeechmaticsTranscriptionProviderTests: XCTestCase {
  func testModelCatalogLiveTranscription_includesSpeechmaticsEnhanced() {
    let ids = ModelCatalog.liveTranscription.map(\.id)

    XCTAssertTrue(ids.contains("speechmatics/enhanced-streaming"))
  }

  func testProviderRegistry_routesSpeechmaticsLiveToSpeechmaticsProvider() async {
    let provider = await TranscriptionProviderRegistry.shared.provider(forModel: "speechmatics/enhanced-streaming")

    XCTAssertEqual(provider?.metadata.id, "speechmatics")
  }

  func testLiveCapabilities_enableLivePolishAndPostStopBudget() {
    let capabilities = ModelCatalog.liveCapabilities(for: "speechmatics/enhanced-streaming")

    XCTAssertTrue(capabilities.supportedSpeedModes.contains(.instant))
    XCTAssertTrue(capabilities.supportedSpeedModes.contains(.livePolish))
    XCTAssertEqual(capabilities.postStopFinalizeBudget, 2.0)
  }

  /// The live path is now the shared SpeakCore client, which is what makes
  /// Speechmatics work on iPhone. The protocol itself is covered by
  /// `SpeechmaticsLiveClientTests`; this asserts the routing seam.
  func testLiveStreamingRunsOnTheSharedSpeakCoreClient() throws {
    let route = try XCTUnwrap(LiveTranscriptionRouting.route(for: "speechmatics/enhanced-streaming"))

    XCTAssertEqual(route.provider, .speechmatics)
    XCTAssertEqual(route.apiModelName, "enhanced")
    XCTAssertEqual(route.apiKeyIdentifier, "speechmatics.apiKey")
    XCTAssertTrue(route.isSupportedOnIOS)
    XCTAssertTrue(
      LiveTranscriptionClientFactory.makeClient(for: route, apiKey: "k", language: nil)
        is SpeechmaticsLiveClient
    )
  }

  func testValidateAPIKey_sendsAuthorizationHeaderToSpeechmaticsJobsEndpoint() async throws {
    let requestObserver = SpeechmaticsRequestObserver()
    SpeechmaticsMockURLProtocol.requestHandler = { request in
      await requestObserver.store(request: request)
      let response = HTTPURLResponse(
        url: try XCTUnwrap(request.url),
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (response, Data(#"{"jobs":[]} "#.utf8))
    }
    defer { SpeechmaticsMockURLProtocol.requestHandler = nil }

    let provider = SpeechmaticsTranscriptionProvider(session: makeMockSession())
    let result = await provider.validateAPIKey("test-speechmatics-key")

    if case .success = result.outcome {
      // Expected.
    } else {
      XCTFail("Expected validation success")
    }
    let capturedRequest = await requestObserver.capturedRequest()
    let request = try XCTUnwrap(capturedRequest)
    XCTAssertEqual(request.url?.host, "eu1.asr.api.speechmatics.com")
    XCTAssertEqual(request.url?.path, "/v2/jobs")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-speechmatics-key")
  }

  private func makeMockSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SpeechmaticsMockURLProtocol.self]
    return URLSession(configuration: configuration)
  }
}

private actor SpeechmaticsRequestObserver {
  private var request: URLRequest?

  func store(request: URLRequest) {
    self.request = request
  }

  func capturedRequest() -> URLRequest? {
    request
  }
}

private final class SpeechmaticsMockURLProtocol: URLProtocol {
  nonisolated(unsafe) static var requestHandler: (@Sendable (URLRequest) async throws -> (HTTPURLResponse, Data))?

  override static func canInit(with request: URLRequest) -> Bool {
    true
  }

  override static func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    guard let handler = Self.requestHandler else {
      XCTFail("SpeechmaticsMockURLProtocol.requestHandler was not set")
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
