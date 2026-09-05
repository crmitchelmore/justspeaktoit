#if !APP_STORE
import Foundation

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

final class AnalyticsTestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var date: Date

  init(_ date: Date) { self.date = date }
  var now: Date { lock.withLock { date } }
  func advance(by interval: TimeInterval) { lock.withLock { date.addTimeInterval(interval) } }
}

final class AnalyticsRecordingURLProtocol: URLProtocol {
  nonisolated(unsafe) static var recorder: AnalyticsRequestRecorder?
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
      client?.urlProtocol(self, didLoad: recorder.responseBody)
      if recorder.finishesResponse { client?.urlProtocolDidFinishLoading(self) }
    }
  }

  override func stopLoading() {
    responseLock.lock()
    defer { responseLock.unlock() }
    stopped = true
  }
}
#endif
