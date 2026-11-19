import Foundation
import os.log

/// Performs a credential-free endpoint probe for a streaming host.
protocol StreamingEndpointWarming: Sendable {
  /// Performs the handshake. Returns `true` when the host answered.
  func warmUp(host: String) async -> Bool
}

/// Completes DNS resolution and an HTTPS exchange against a streaming
/// provider's host (issue #663).
///
/// Deliberately a bare `HEAD /` with no credential and no API path: the point is
/// to populate resolver state and potentially seed TLS resumption, not to talk
/// to the provider. It does not pre-connect the WebSocket or claim that an HTTP
/// connection pool is reusable by a dedicated live-client `URLSession`. No API
/// key leaves the machine and no provider-side transcription session is created.
/// Any HTTP status (including 401/404) counts as success.
///
/// Mirrors the existing `OpenRouterAPIClient.warmUp()` approach used for the
/// post-processing connection.
struct StreamingEndpointWarmer: StreamingEndpointWarming {
  private let session: URLSession
  private let timeout: TimeInterval
  private let logger = Logger(subsystem: "com.github.speakapp", category: "StreamWarmUp")

  /// Only providers whose live client also uses `URLSession.shared` opt into
  /// this probe. Dedicated-session clients are excluded by `LiveStreamWarmUp`.
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
