import Foundation
import XCTest

/// Serial counter for multi-page stubs; the protocol stub runs its handler off
/// the test's own thread.
final class CartesiaTTSPageCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0

  func next() -> Int {
    lock.lock()
    defer { lock.unlock() }
    let current = value
    value += 1
    return current
  }
}

/// Intercepts Cartesia HTTP traffic and records the request the transport built.
final class CartesiaTTSMockURLProtocol: URLProtocol {
#if compiler(>=5.10)
  nonisolated(unsafe) static var requestHandler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
  /// `URLProtocol` strips `httpBody` from the request it hands the subclass, so
  /// the body is recovered from `httpBodyStream` and reattached here.
  nonisolated(unsafe) static var lastRequest: URLRequest?
#else
  static var requestHandler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
  static var lastRequest: URLRequest?
#endif

  static func reset() {
    lastRequest = nil
  }

  override static func canInit(with request: URLRequest) -> Bool {
    true
  }

  override static func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    guard let handler = Self.requestHandler else {
      XCTFail("CartesiaTTSMockURLProtocol.requestHandler was not set")
      return
    }

    var recorded = request
    if recorded.httpBody == nil, let stream = request.httpBodyStream {
      recorded.httpBody = Self.readBody(from: stream)
    }
    Self.lastRequest = recorded

    do {
      let (response, data) = try handler(recorded)
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}

  private static func readBody(from stream: InputStream) -> Data {
    stream.open()
    defer { stream.close() }
    var data = Data()
    let bufferSize = 4096
    var buffer = [UInt8](repeating: 0, count: bufferSize)
    while stream.hasBytesAvailable {
      let read = stream.read(&buffer, maxLength: bufferSize)
      guard read > 0 else { break }
      data.append(buffer, count: read)
    }
    return data
  }
}
