import Foundation
import Network

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
