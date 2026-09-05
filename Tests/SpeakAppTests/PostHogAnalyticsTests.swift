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
    XCTAssertEqual(properties["analytics_schema_version"] as? Int, 2)
    XCTAssertNil(properties["transcript"])
    XCTAssertNil(properties["audio"])
  }

  func testCapturePreservesNativeScalarPropertyTypes() async throws {
    let recorder = RequestRecorder()
    let sink = makeSink(recorder: recorder)
    try await sink.reopen()
    let payload = ProductAnalyticsPayload(
      event: .keyboardEnabledState(enabled: true),
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

    try await sink.capture(payload)

    let request = try XCTUnwrap(recorder.requests.first)
    let bodyData = try XCTUnwrap(request.httpBody)
    let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
    let properties = try XCTUnwrap(body["properties"] as? [String: Any])
    XCTAssertEqual(properties["enabled"] as? Bool, true)
    XCTAssertEqual(properties["analytics_schema_version"] as? Int, 2)
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

  func testConcurrentCaptureUsesOneFlushAndSendsEachEntryOnce() async throws {
    let started = expectation(description: "First request is in flight")
    let recorder = RequestRecorder(holdResponses: true) { count in
      if count == 1 { started.fulfill() }
    }
    let queueURL = temporaryQueueURL()
    let sink = makeSink(queueURL: queueURL, recorder: recorder)
    try await sink.reopen()
    let first = Task { try await sink.capture(makePayload()) }
    await fulfillment(of: [started], timeout: 2)

    let enqueued = expectation(description: "Concurrent capture queues without another flush")
    let second = Task {
      try await sink.capture(makePayload())
      enqueued.fulfill()
    }
    await fulfillment(of: [enqueued], timeout: 2)
    XCTAssertEqual(recorder.requests.count, 1)
    recorder.releaseResponses()
    try await first.value
    try await second.value

    XCTAssertEqual(recorder.requests.count, 2)
    XCTAssertFalse(FileManager.default.fileExists(atPath: queueURL.path))
  }

  func testPurgeCancelsInFlightFlushAndCannotRemoveANewConsentQueuesEntry() async throws {
    let started = expectation(description: "Request is in flight")
    let restarted = expectation(description: "New consent starts a fresh request")
    let recorder = RequestRecorder(holdResponses: true) { count in
      if count == 1 { started.fulfill() }
      if count == 2 { restarted.fulfill() }
    }
    let queueURL = temporaryQueueURL()
    let sink = makeSink(queueURL: queueURL, recorder: recorder)
    try await sink.reopen()
    let first = Task { try? await sink.capture(makePayload()) }
    await fulfillment(of: [started], timeout: 2)

    try await sink.purge()
    await sink.close()
    XCTAssertFalse(FileManager.default.fileExists(atPath: queueURL.path))
    try await sink.capture(makePayload())
    XCTAssertEqual(recorder.requests.count, 1)

    try await sink.reopen()
    let second = Task { try await sink.capture(makePayload()) }
    await fulfillment(of: [restarted], timeout: 2)
    recorder.releaseResponses()
    await first.value
    try await second.value
    XCTAssertEqual(recorder.requests.count, 2)
    XCTAssertFalse(FileManager.default.fileExists(atPath: queueURL.path))
  }

  func testReopenPrunesExpiredLegacyQueueBeforeSendingAndPersistsTheResult() async throws {
    let clock = TestClock(Date())
    let queueURL = temporaryQueueURL()
    try writeLegacyQueue(count: 1, createdAt: clock.now, to: queueURL)
    let recorder = RequestRecorder()
    let sink = makeSink(queueURL: queueURL, recorder: recorder, now: { clock.now })
    clock.advance(by: 8 * 24 * 60 * 60)

    try await sink.reopen()

    XCTAssertTrue(recorder.requests.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: queueURL.path))
  }

  func testReopenPersistsThousandEventCapWithOldestFirstEviction() async throws {
    let queueURL = temporaryQueueURL()
    try writeLegacyQueue(count: 1_001, createdAt: Date(), to: queueURL)
    let recorder = RequestRecorder(statusCode: 500)
    let sink = makeSink(queueURL: queueURL, recorder: recorder)

    do {
      try await sink.reopen()
      XCTFail("Expected the simulated server failure")
    } catch {}

    let stored = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: queueURL)) as? [[String: Any]])
    XCTAssertEqual(stored.count, 1_000)
    XCTAssertEqual(stored.first?["distinctID"] as? String, "install-1")
    XCTAssertEqual(stored.last?["distinctID"] as? String, "install-1000")
  }

  private func writeLegacyQueue(count: Int, createdAt: Date, to url: URL) throws {
    let events: [[String: Any]] = (0 ..< count).map { index in
      [
        "createdAt": createdAt.timeIntervalSinceReferenceDate,
        "event": "app_active_daily",
        "distinctID": "install-\(index)",
        "properties": ["analytics_schema_version": 2]
      ]
    }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: events).write(to: url)
  }

  private func makeSink(
    queueURL: URL? = nil,
    recorder: RequestRecorder,
    now: @escaping @Sendable () -> Date = { Date() }
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
      ),
      now: now
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
  private var heldResponses: [() -> Void] = []
  private var holdResponses: Bool
  private let onRequest: (Int) -> Void
  let statusCode: Int

  init(statusCode: Int = 200, holdResponses: Bool = false, onRequest: @escaping (Int) -> Void = { _ in }) {
    self.statusCode = statusCode
    self.holdResponses = holdResponses
    self.onRequest = onRequest
  }
  var requests: [URLRequest] { lock.withLock { storedRequests } }

  func append(_ request: URLRequest, respond: @escaping () -> Void) {
    let (count, shouldRespond) = lock.withLock {
      storedRequests.append(request)
      if holdResponses { heldResponses.append(respond) }
      return (storedRequests.count, !holdResponses)
    }
    onRequest(count)
    if shouldRespond { respond() }
  }

  func releaseResponses() {
    let responses = lock.withLock {
      holdResponses = false
      let responses = heldResponses
      heldResponses.removeAll()
      return responses
    }
    responses.forEach { $0() }
  }
}

private final class TestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var date: Date

  init(_ date: Date) { self.date = date }
  var now: Date { lock.withLock { date } }
  func advance(by interval: TimeInterval) { lock.withLock { date.addTimeInterval(interval) } }
}

private final class RecordingURLProtocol: URLProtocol {
  nonisolated(unsafe) static var recorder: RequestRecorder?
  private let responseLock = NSRecursiveLock()
  private var stopped = false

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
    let response = HTTPURLResponse(
      url: url,
      statusCode: recorder.statusCode,
      httpVersion: "HTTP/1.1",
      headerFields: nil
    )!
    recorder.append(recordedRequest) { [self] in
      responseLock.lock()
      defer { responseLock.unlock() }
      guard !stopped else { return }
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: Data())
      client?.urlProtocolDidFinishLoading(self)
    }
  }

  override func stopLoading() {
    responseLock.lock()
    defer { responseLock.unlock() }
    stopped = true
  }
}
#endif
