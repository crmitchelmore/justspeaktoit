import Foundation

/// A transport failure that carries the WebSocket close code the peer sent.
///
/// A provider that treats the server's close as its end-of-session signal
/// needs that code to tell a completed session from a dropped one. A failure
/// without this conformance, or with a `nil` code, reports no close frame and
/// is therefore never a completion. Adapters conform their own error types;
/// providers read only this property and never parse transport messages.
public protocol StreamingWebSocketCloseReporting: Error {
    /// The status code from the peer's close frame (RFC 6455 section 7.4),
    /// or `nil` when the transport ended without receiving one.
    var webSocketCloseCode: Int? { get }
}
