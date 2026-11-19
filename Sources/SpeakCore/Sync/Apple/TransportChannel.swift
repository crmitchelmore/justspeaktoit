import Foundation
import Network

// MARK: - Channel

/// One message channel over an established `NWConnection`.
///
/// The phone and the Mac both send and receive through this type, so the frame
/// format, the encryption, the size ceilings and the close behaviour have
/// exactly one implementation. Callers see `TransportMessage` values and never
/// touch bytes.
///
/// After `start()`, the phone calls `establishSecureSession(pairingCode:)` and
/// the Mac calls `acceptSecureSession(authorize:)`. `send` and `receive` refuse
/// to run until that handshake has succeeded, and from then on every frame is
/// sealed (see `TransportSecureSession.swift` and the handshake in
/// `TransportChannel+SecureSession.swift`).
///
/// Receive is sequential: run one receive loop per channel.
public actor TransportChannel {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    private var limit = TransportFrameLimit.handshake
    private var hasStarted = false
    var session: TransportSessionKeys?
    var sessionCredentialID: UUID?
    var sessionUsedCredential = false

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

    /// Whether the handshake has finished and every frame is now sealed.
    public var isEncrypted: Bool {
        self.session != nil
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

    // MARK: - Messages

    /// Encodes, seals and sends one message as a binary WebSocket frame.
    public func send(_ message: TransportMessage) async throws {
        guard var session = self.session else { throw TransportSecurityError.notEncrypted }
        let plaintext = try self.encoder.encode(message)
        guard self.limit.admits(byteCount: plaintext.count + TransportFrameCipher.overhead) else {
            throw TransportChannelError.frameTooLarge(
                byteCount: plaintext.count + TransportFrameCipher.overhead,
                maximumBytes: self.limit.maximumBytes
            )
        }
        let sealed = try session.outbound.seal(plaintext)
        self.session = session
        try await self.sendFrame(sealed)
    }

    /// Waits for the next message. Throws when the peer closes, when a frame
    /// breaks the size ceiling, fails authentication, or is not a valid message.
    public func receive() async throws -> TransportMessage {
        guard self.session != nil else { throw TransportSecurityError.notEncrypted }
        let frame = try await self.receiveFrame()
        // Re-read after the suspension: a concurrent send may have advanced the
        // outbound counter while this receive waited.
        guard var session = self.session else { throw TransportSecurityError.notEncrypted }
        let plaintext = try session.inbound.open(frame)
        self.session = session
        return try self.decoder.decode(TransportMessage.self, from: plaintext)
    }

    /// Sends a message without encryption.
    ///
    /// Only a refusal before the session exists goes out this way; tests use it
    /// to play a peer that does not encrypt.
    func sendPlaintext(_ message: TransportMessage) async throws {
        let data = try self.encoder.encode(message)
        guard self.limit.admits(byteCount: data.count) else {
            throw TransportChannelError.frameTooLarge(byteCount: data.count, maximumBytes: self.limit.maximumBytes)
        }
        try await self.sendFrame(data)
    }

    /// Receives a message whether or not it is sealed. Tests use it to watch a
    /// plaintext peer being refused.
    func receiveAnyMessage() async throws -> TransportMessage {
        if self.session != nil { return try await self.receive() }
        return try self.decoder.decode(TransportMessage.self, from: try await self.receiveFrame())
    }

    func sendFrame(_ data: Data) async throws {
        guard self.limit.admits(byteCount: data.count) else {
            throw TransportChannelError.frameTooLarge(byteCount: data.count, maximumBytes: self.limit.maximumBytes)
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

    /// Closes the connection. Safe to call more than once, and from any context.
    public nonisolated func close() {
        self.connection.cancel()
    }

    func receiveFrame() async throws -> Data {
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
