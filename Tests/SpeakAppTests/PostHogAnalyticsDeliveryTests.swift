#if !APP_STORE
@testable import SpeakApp
import SpeakCore
import XCTest

final class PostHogAnalyticsDeliveryTests: XCTestCase {
  func testConcurrentCaptureAfterTransientFailure_RetriesRetainedQueueWithoutAnotherCapture() async throws {
    let started = expectation(description: "First request is held")
    let delivered = expectation(description: "Retry sends both retained entries")
    let recorder = AnalyticsRequestRecorder(statusCodes: [500, 200], holdResponses: true) { count in
      if count == 1 { started.fulfill() }
      if count == 3 { delivered.fulfill() }
    }
    let fixture = makeFixture(recorder: recorder, retryDelays: [.milliseconds(10)])
    try await fixture.sink.reopen()
    let first = Task { try? await fixture.sink.capture(makePayload()) }
    await fulfillment(of: [started], timeout: 2)
    try await fixture.sink.capture(makePayload())
    recorder.releaseResponses()
    await first.value
    await fulfillment(of: [delivered], timeout: 2)
    XCTAssertEqual(recorder.requests.count, 3)
    await fixture.sink.close()
  }

  func testStalledResponse_DeadlineReturnsAndRetainsEvent() async throws {
    let recorder = AnalyticsRequestRecorder(responseBody: Data([1]), finishesResponse: false)
    let fixture = makeFixture(recorder: recorder, requestDeadline: .milliseconds(30))
    try await fixture.sink.reopen()
    let finished = expectation(description: "Delivery returns despite unfinished response")
    let capture = Task {
      do {
        try await fixture.sink.capture(makePayload())
        XCTFail("Expected a delivery deadline failure")
      } catch {}
      finished.fulfill()
    }
    await fulfillment(of: [finished], timeout: 2)
    await fixture.sink.close()
    await capture.value
    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.queueURL.path))
  }

  func testOversizedResponse_FailsWithoutAcknowledgingOrAutomaticallyRetrying() async throws {
    let unexpectedRetry = expectation(description: "Oversized response is not retried")
    unexpectedRetry.isInverted = true
    let recorder = AnalyticsRequestRecorder(responseBody: Data(repeating: 1, count: 16_385)) { count in
      if count > 1 { unexpectedRetry.fulfill() }
    }
    let fixture = makeFixture(recorder: recorder, retryDelays: [.milliseconds(10)])
    try await fixture.sink.reopen()
    do {
      try await fixture.sink.capture(makePayload())
      XCTFail("Expected response size rejection")
    } catch let error as URLError {
      XCTAssertEqual(error.code, .dataLengthExceedsMaximum)
    }
    await fulfillment(of: [unexpectedRetry], timeout: 0.1)
    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.queueURL.path))
    await fixture.sink.close()
  }

  func testTransientFailure_AutomaticRetriesStopAtConfiguredLimit() async throws {
    let attempts = expectation(description: "Initial attempt plus two retries")
    attempts.expectedFulfillmentCount = 3
    let excessAttempt = expectation(description: "No unbounded retries")
    excessAttempt.isInverted = true
    let recorder = AnalyticsRequestRecorder(statusCode: 503) { count in
      if count <= 3 { attempts.fulfill() } else { excessAttempt.fulfill() }
    }
    let fixture = makeFixture(recorder: recorder, retryDelays: [.milliseconds(10), .milliseconds(10)])
    try await fixture.sink.reopen()
    try? await fixture.sink.capture(makePayload())
    await fulfillment(of: [attempts], timeout: 2)
    await fulfillment(of: [excessAttempt], timeout: 0.1)
    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.queueURL.path))
    await fixture.sink.close()
  }

  func testPermanentRejection_DoesNotAutomaticallyRetry() async throws {
    let unexpectedRetry = expectation(description: "Revoked key is not retried")
    unexpectedRetry.isInverted = true
    let recorder = AnalyticsRequestRecorder(statusCode: 401) { count in
      if count > 1 { unexpectedRetry.fulfill() }
    }
    let fixture = makeFixture(recorder: recorder, retryDelays: [.milliseconds(10)])
    try await fixture.sink.reopen()
    try? await fixture.sink.capture(makePayload())
    await fulfillment(of: [unexpectedRetry], timeout: 0.1)
    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.queueURL.path))
    await fixture.sink.close()
  }

  func testWithdrawal_CancelsPendingRetryAndPurgesRetainedQueue() async throws {
    let unexpectedRetry = expectation(description: "Withdrawal cancels scheduled retry")
    unexpectedRetry.isInverted = true
    let recorder = AnalyticsRequestRecorder(statusCode: 503) { count in
      if count > 1 { unexpectedRetry.fulfill() }
    }
    let fixture = makeFixture(recorder: recorder, retryDelays: [.milliseconds(50)])
    try await fixture.sink.reopen()
    try? await fixture.sink.capture(makePayload())
    try await fixture.sink.purge()
    await fixture.sink.close()
    await fulfillment(of: [unexpectedRetry], timeout: 0.15)
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.queueURL.path))
  }

  private func makeFixture(
    recorder: AnalyticsRequestRecorder,
    requestDeadline: Duration = .seconds(1),
    retryDelays: [Duration] = []
  ) -> (sink: PostHogProductAnalyticsSink, queueURL: URL) {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [AnalyticsRecordingURLProtocol.self]
    AnalyticsRecordingURLProtocol.recorder = recorder
    let queueURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString).appendingPathComponent("analytics_queue.json")
    let sink = PostHogProductAnalyticsSink(
      queueURL: queueURL,
      session: URLSession(configuration: configuration),
      configuration: (projectKey: "phc_test", endpoint: URL(string: "https://eu.i.posthog.com/capture")!),
      requestDeadline: requestDeadline,
      retryDelays: retryDelays
    )
    return (sink, queueURL)
  }

  private func makePayload() -> ProductAnalyticsPayload {
    ProductAnalyticsPayload(
      event: .appActiveDaily,
      context: ProductAnalyticsContext(
        platform: .macOS, appVersion: "2.63.6", build: "42", osMajorMinor: "26.0",
        distributionChannel: .direct, localeLanguageCode: "en", architecture: "arm64"
      ),
      distinctID: UUID()
    )
  }
}
#endif
