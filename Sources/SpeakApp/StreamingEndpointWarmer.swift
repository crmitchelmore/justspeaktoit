import Foundation
import os.log

/// Warms the network path to a streaming transcription host.
protocol StreamingEndpointWarming: Sendable {
  /// Performs the handshake. Returns `true` when the host answered.
  func warmUp(host: String) async -> Bool
}

/// Completes DNS resolution, TCP connect and the TLS handshake against a
/// streaming provider's host so the `wss://` upgrade at session start does not
/// pay for them (issue #663).
///
/// Deliberately a bare `HEAD /` with no credential and no API path: the point is
/// to populate the resolver cache, the URLSession connection pool and the
/// process TLS session cache, not to talk to the provider. No API key leaves the
/// machine, and no provider-side transcription session is created — see
/// ``LiveStreamWarmUp`` for why a fully pre-connected WebSocket is not safe for
/// any of the supported providers. Any HTTP status (including 401/404) counts as
/// success; the bytes we wanted were the handshake.
///
/// Mirrors the existing `OpenRouterAPIClient.warmUp()` approach used for the
/// post-processing connection.
struct StreamingEndpointWarmer: StreamingEndpointWarming {
  private let session: URLSession
  private let timeout: TimeInterval
  private let logger = Logger(subsystem: "com.github.speakapp", category: "StreamWarmUp")

  /// Uses `URLSession.shared` on purpose: that is the session the streaming
  /// clients connect through, so the warmed resolver entry, connection pool and
  /// TLS session ticket are the ones session start will actually reach for.
  init(session: URLSession = .shared, timeout: TimeInterval = 5) {
    self.session = session
    self.timeout = timeout
  }

  func warmUp(host: String) async -> Bool {
    guard var components = URLComponents(string: "https://\(host)") else { return false }
    components.path = "/"
    guard let url = components.url else { return false }

    var request = URLRequest(url: url)
    request.httpMethod = "HEAD"
    request.timeoutInterval = self.timeout

    let startedAt = CFAbsoluteTimeGetCurrent()
    do {
      _ = try await self.session.data(for: request)
      let elapsed = String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
      self.logger.debug("Warmed \(host, privacy: .public) in \(elapsed, privacy: .public)ms")
      return true
    } catch {
      self.logger.debug("Warm-up for \(host, privacy: .public) failed; session start will connect cold")
      return false
    }
  }
}
