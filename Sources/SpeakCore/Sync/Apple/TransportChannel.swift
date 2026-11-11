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

// MARK: - Channel

/// One message channel over an established `NWConnection`.
///
/// The phone and the Mac both send and receive through this type, so the frame
/// format, the size ceilings and the close behaviour have exactly one
/// implementation. Callers see `TransportMessage` values and never touch bytes.
///
/// Receive is sequential: run one receive loop per channel.
public actor TransportChannel {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var limit = TransportFrameLimit.handshake
    private var hasStarted = false

    public init(connection: NWConnection) {
        self.connection = connection
        self.queue = DispatchQueue(label: "com.justspeaktoit.transport.channel")
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder.dateDecodingStrategy = .iso8601
    }

    /// Builds a channel to `endpoint` without connecting it yet.
    public static func connecting(to endpoint: NWEndpoint, includesPeerToPeer: Bool = true) -> TransportChannel {
        TransportChannel(
            connection: NWConnection(
                to: endpoint,
                using: SpeakTransportWire.parameters(includesPeerToPeer: includesPeerToPeer)
            )
        )
    }

    /// Lifts the frame ceiling to session size.
    ///
    /// Call this only after the peer authenticates: it is the capacity a paired
    /// device earns by presenting the pairing code.
    public func admitSessionFrames() {
        self.limit = .session
    }

    /// The ceiling frames are currently held to.
    public var frameLimit: TransportFrameLimit {
        self.limit
    }

    /// Runs the WebSocket handshake and waits for the connection to be usable.
    public func start() async throws {
        guard !self.hasStarted else { return }
        self.hasStarted = true

        let connection = self.connection
        let queue = self.queue

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumer = SingleShotResumer(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    resumer.finish(with: nil)
                case .failed(let error):
                    resumer.finish(with: .connectionFailed(error.localizedDescription))
                case .cancelled:
                    resumer.finish(with: .closed)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    /// Encodes and sends one message as a binary WebSocket frame.
    public func send(_ message: TransportMessage) async throws {
        let data = try self.encoder.encode(message)
        guard self.limit.admits(byteCount: data.count) else {
            throw TransportChannelError.frameTooLarge(
                byteCount: data.count,
                maximumBytes: self.limit.maximumBytes
            )
        }

        let connection = self.connection
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let context = NWConnection.ContentContext(
                identifier: "speak.transport",
                metadata: [NWProtocolWebSocket.Metadata(opcode: .binary)]
            )
            connection.send(
                content: data,
                contentContext: context,
                isComplete: true,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(
                            throwing: TransportChannelError.connectionFailed(error.localizedDescription)
                        )
                    } else {
                        continuation.resume()
                    }
                }
            )
        }
    }

    /// Waits for the next message. Throws when the peer closes, when a frame
    /// breaks the size ceiling, or when the payload is not a valid message.
    public func receive() async throws -> TransportMessage {
        let data = try await self.receiveFrame()
        return try self.decoder.decode(TransportMessage.self, from: data)
    }

    /// Closes the connection. Safe to call more than once, and from any context.
    public nonisolated func close() {
        self.connection.cancel()
    }

    private func receiveFrame() async throws -> Data {
        let connection = self.connection
        let limit = self.limit

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receiveMessage { content, context, _, error in
                if let error {
                    continuation.resume(
                        throwing: TransportChannelError.connectionFailed(error.localizedDescription)
                    )
                    return
                }

                let metadata = context?.protocolMetadata(
                    definition: NWProtocolWebSocket.definition
                ) as? NWProtocolWebSocket.Metadata

                if metadata?.opcode == .close {
                    continuation.resume(throwing: TransportChannelError.closed)
                    return
                }
                guard let content, !content.isEmpty else {
                    continuation.resume(throwing: TransportChannelError.closed)
                    return
                }
                guard metadata?.opcode == .binary || metadata?.opcode == .text else {
                    continuation.resume(throwing: TransportChannelError.unsupportedFrame)
                    return
                }
                guard limit.admits(byteCount: content.count) else {
                    continuation.resume(
                        throwing: TransportChannelError.frameTooLarge(
                            byteCount: content.count,
                            maximumBytes: limit.maximumBytes
                        )
                    )
                    return
                }
                continuation.resume(returning: content)
            }
        }
    }
}

// MARK: - Continuation guard

/// Resumes a continuation exactly once.
///
/// `NWConnection.stateUpdateHandler` reports every state change, so a connection
/// that goes ready and later fails would resume twice and trap.
private final class SingleShotResumer: @unchecked Sendable {
    private let continuation: CheckedContinuation<Void, Error>
    private let lock = NSLock()
    private var hasFinished = false

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func finish(with error: TransportChannelError?) {
        let isFirst: Bool = self.lock.withLock {
            guard !self.hasFinished else { return false }
            self.hasFinished = true
            return true
        }
        guard isFirst else { return }

        if let error {
            self.continuation.resume(throwing: error)
        } else {
            self.continuation.resume()
        }
    }
}
