import Foundation
import Network

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

// MARK: - Wire format

/// The single definition of how "Send to Mac" frames travel between the phone
/// and the Mac.
///
/// Both endpoints build their `NWParameters` here, so the two sides cannot drift
/// apart again. Before this existed the phone spoke WebSocket while the Mac read
/// a hand-rolled four-byte length prefix, so the Mac parsed the letters of
/// `GET ` as a frame length and no message ever decoded (issue #688).
///
/// The chosen wire is WebSocket (RFC 6455) over TCP: the system frames the
/// messages on both platforms, which removes the hand-rolled length prefix that
/// caused the mismatch.
public enum SpeakTransportWire {
    /// Request path in the WebSocket handshake.
    ///
    /// The server accepts any path. This one keeps URLs readable for a Mac
    /// addressed directly rather than through Bonjour.
    public static let endpointPath = "/speak"

    /// URL endpoint for a Mac reached by address.
    ///
    /// A client must address the server either as this URL or as the Bonjour
    /// service endpoint that discovery returns. A bare host-and-port endpoint
    /// does not work: the WebSocket handshake needs a request line, so the
    /// connection stalls in `preparing` and then aborts.
    public static func endpoint(host: String, port: UInt16) -> NWEndpoint? {
        guard let url = URL(string: "ws://\(host):\(port)\(self.endpointPath)") else { return nil }
        return .url(url)
    }

    /// Parameters for one end of the transport.
    ///
    /// - Parameter includesPeerToPeer: Whether to offer peer-to-peer interfaces.
    ///   The shipping server and client both do; tests that bind loopback do not.
    public static func parameters(includesPeerToPeer: Bool) -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = includesPeerToPeer

        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        // Hard ceiling inside the framing layer itself: an oversized frame is
        // refused before its bytes are buffered, so no peer — authenticated or
        // not — can drive an unbounded allocation.
        websocket.maximumMessageSize = TransportFrameLimit.session.maximumBytes
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)

        return parameters
    }
}
