#if !APP_STORE
import Foundation
import SpeakTestSupport

final class AnalyticsRequestRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storedRequests: [URLRequest] = []
  private var heldResponses: [() -> Void] = []
  private var holdResponses: Bool
  private let onRequest: (Int) -> Void
  private let statusCodes: [Int]
  let responseBody: Data
  let finishesResponse: Bool

  init(
    statusCode: Int = 200,
    statusCodes: [Int] = [],
    responseBody: Data = Data(),
    finishesResponse: Bool = true,
    holdResponses: Bool = false,
    onRequest: @escaping (Int) -> Void = { _ in }
  ) {
    self.statusCodes = statusCodes.isEmpty ? [statusCode] : statusCodes
    self.responseBody = responseBody
    self.finishesResponse = finishesResponse
    self.holdResponses = holdResponses
    self.onRequest = onRequest
  }
  var requests: [URLRequest] { lock.withLock { storedRequests } }
  var statusCode: Int { lock.withLock { statusCodes[min(storedRequests.count, statusCodes.count - 1)] } }

  func append(_ request: URLRequest, respond: @escaping () -> Void) {
    let (count, shouldRespond) = lock.withLock {
      storedRequests.append(request)
      if holdResponses { heldResponses.append(respond) }
      return (storedRequests.count, !holdResponses)
    }
    onRequest(count)
    if shouldRespond { respond() }
  }

  /// Records the request and suspends until this recorder is willing to
  /// respond — immediately unless `holdResponses` is set, in which case the
  /// caller resumes on `releaseResponses()`. Lets the shared `StubURLProtocol`
  /// handler express the held-response behaviour that the bespoke protocol
  /// subclass used to implement by hand (issue #1124).
  func append(_ request: URLRequest) async {
    await withCheckedContinuation { continuation in
      append(request) { continuation.resume() }
    }
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

extension AnalyticsRequestRecorder {
  /// Installs this recorder as the shared stub's handler. Replaces the former
  /// bespoke `AnalyticsRecordingURLProtocol` (issue #1124): the held-response
  /// behaviour is now expressed by awaiting the recorder inside the handler.
  func installAsStubHandler() {
    StubURLProtocol.handler = { [self] request in
      var recorded = request
      recorded.httpBody = StubURLProtocol.body(of: request)
      // Read before appending: the status sequence is indexed by the number of
      // requests recorded so far, which is what the old subclass did.
      let statusCode = self.statusCode
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: statusCode,
        httpVersion: "HTTP/1.1",
        headerFields: nil
      )!
      await self.append(recorded)
      return self.finishesResponse
        ? .respond(response, self.responseBody)
        : .respondWithoutFinishing(response, self.responseBody)
    }
  }
}

final class AnalyticsTestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var date: Date

  init(_ date: Date) { self.date = date }
  var now: Date { lock.withLock { date } }
  func advance(by interval: TimeInterval) { lock.withLock { date.addTimeInterval(interval) } }
}

#endif
