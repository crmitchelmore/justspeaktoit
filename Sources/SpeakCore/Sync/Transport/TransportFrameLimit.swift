import Foundation

// MARK: - Frame limits

/// Ceiling on the size of one transport frame.
///
/// Two ceilings exist because a peer earns capacity. Until it presents a valid
/// pairing code it may only send frames large enough for a hello and an
/// authenticate, so a stranger on the local network cannot make either side
/// buffer megabytes before the pairing code is checked.
public struct TransportFrameLimit: Equatable, Sendable {
    /// Applies until the peer authenticates. A hello plus an authenticate frame
    /// come to a few hundred bytes; 4 KiB leaves room for long device names.
    public static let handshake = TransportFrameLimit(maximumBytes: 4 * 1024)

    /// Applies to an authenticated session. Transcript and session-end frames
    /// carry dictated text, so the ceiling is generous but still finite.
    public static let session = TransportFrameLimit(maximumBytes: 1024 * 1024)

    public let maximumBytes: Int

    private init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    /// Whether a frame of `byteCount` bytes may cross the wire.
    public func admits(byteCount: Int) -> Bool {
        byteCount > 0 && byteCount <= self.maximumBytes
    }
}

// MARK: - Errors

public enum TransportChannelError: Error, Equatable {
    /// The connection could not be established, or it dropped mid-flight.
    case connectionFailed(String)
    /// The peer closed the connection, or it was cancelled locally.
    case closed
    /// A frame exceeded the ceiling that applies to the current phase.
    case frameTooLarge(byteCount: Int, maximumBytes: Int)
    /// A frame arrived with an opcode this protocol does not carry data in.
    case unsupportedFrame
}

extension TransportChannelError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .connectionFailed(let reason):
            "Connection failed: \(reason)"
        case .closed:
            "The connection closed"
        case .frameTooLarge(let byteCount, let maximumBytes):
            "Message of \(byteCount) bytes is above the \(maximumBytes) byte limit"
        case .unsupportedFrame:
            "The peer sent a frame this protocol does not use"
        }
    }
}
