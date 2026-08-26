#if !APP_STORE
@testable import SpeakApp
import SpeakCore
import XCTest

final class PostHogAnalyticsTests: XCTestCase {
  func testCaptureIsSilentUntilSinkIsReopenedAfterConsent() async throws {
    let recorder = RequestRecorder()
    let sink = makeSink(recorder: recorder)

    try await sink.capture(makePayload())

    XCTAssertEqual(recorder.requests.count, 0)
  }

  func testOptedInCaptureUsesOnlyAuditedPostHogCaptureEndpoint() async throws {
    let recorder = RequestRecorder()
    let sink = makeSink(recorder: recorder)
    try await sink.reopen()

    try await sink.capture(makePayload())

    let request = try XCTUnwrap(recorder.requests.first)
    XCTAssertEqual(request.url?.absoluteString, "https://eu.i.posthog.com/capture")
    XCTAssertEqual(request.httpMethod, "POST")
    let bodyData = try XCTUnwrap(request.httpBody)
    let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
    XCTAssertEqual(body["api_key"] as? String, "phc_test")
    XCTAssertEqual(body["event"] as? String, "app_active_daily")
    let properties = try XCTUnwrap(body["properties"] as? [String: Any])
    XCTAssertEqual(properties["platform"] as? String, "macOS")
    XCTAssertNil(properties["transcript"])
    XCTAssertNil(properties["audio"])
  }

  func testPurgeDeletesQueuedEventsAfterWithdrawal() async throws {
    let queueURL = temporaryQueueURL()
    let recorder = RequestRecorder(statusCode: 500)
    let sink = makeSink(queueURL: queueURL, recorder: recorder)
    try? await sink.reopen()
    try? await sink.capture(makePayload())
    XCTAssertTrue(FileManager.default.fileExists(atPath: queueURL.path))

    try await sink.purge()

    XCTAssertFalse(FileManager.default.fileExists(atPath: queueURL.path))
  }

  private func makeSink(
    queueURL: URL? = nil,
    recorder: RequestRecorder
  ) -> PostHogProductAnalyticsSink {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RecordingURLProtocol.self]
    RecordingURLProtocol.recorder = recorder
    return PostHogProductAnalyticsSink(
      queueURL: queueURL ?? temporaryQueueURL(),
      session: URLSession(configuration: configuration),
      configuration: (
        projectKey: "phc_test",
        endpoint: URL(string: "https://eu.i.posthog.com/capture")!
      )
    )
  }

  private func makePayload() -> ProductAnalyticsPayload {
    ProductAnalyticsPayload(
      event: .appActiveDaily,
      context: ProductAnalyticsContext(
        platform: .macOS,
        appVersion: "2.63.6",
        build: "202608250001",
        osMajorMinor: "26.0",
        distributionChannel: .direct,
        localeLanguageCode: "en",
        architecture: "arm64"
      ),
      distinctID: UUID()
    )
  }

  private func temporaryQueueURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathComponent("analytics_queue.json")
  }
}

private final class RequestRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storedRequests: [URLRequest] = []
  let statusCode: Int

  init(statusCode: Int = 200) { self.statusCode = statusCode }
  var requests: [URLRequest] { lock.withLock { storedRequests } }
  func append(_ request: URLRequest) { lock.withLock { storedRequests.append(request) } }
}

private final class RecordingURLProtocol: URLProtocol {
  nonisolated(unsafe) static var recorder: RequestRecorder?

  override static func canInit(with _: URLRequest) -> Bool { true }
  override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let recorder = Self.recorder, let url = request.url else { return }
    var recordedRequest = request
    if recordedRequest.httpBody == nil, let stream = recordedRequest.httpBodyStream {
      stream.open()
      defer { stream.close() }
      var data = Data()
      var buffer = [UInt8](repeating: 0, count: 4_096)
      while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        guard count > 0 else { break }
        data.append(buffer, count: count)
      }
      recordedRequest.httpBody = data
    }
    recorder.append(recordedRequest)
    let response = HTTPURLResponse(
      url: url,
      statusCode: recorder.statusCode,
      httpVersion: "HTTP/1.1",
      headerFields: nil
    )!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data())
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}
#endif
