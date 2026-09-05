#if os(macOS)
import Foundation
import Network
import SpeakCore

// MARK: - Individual Connection Handler

/// Server half of one paired device's session.
///
/// A device must greet, then authenticate, before the server accepts anything
/// that carries text. Until it authenticates it is held to the handshake frame
/// ceiling, so an unpaired peer on the local network can neither insert text on
/// this Mac nor make it buffer a large frame.
@MainActor
final class TransportConnection {
    private let channel: TransportChannel
    private var receiveTask: Task<Void, Never>?
    private var isAuthenticated = false
    private var deviceId: String?
    private var deviceName: String?
    private(set) var currentSessionId: String?

    var onAuthenticated: ((String, String) -> Void)?
    var onTranscriptChunk: ((String, String) -> Void)?
    var onDisconnected: (() -> Void)?

    init(connection: NWConnection) {
        self.channel = TransportChannel(connection: connection)
    }

    func start() {
        self.receiveTask = Task { @MainActor [weak self] in
            await self?.run()
        }
    }

    func disconnect() {
        self.receiveTask?.cancel()
        self.receiveTask = nil
        self.channel.close()
    }

    // MARK: - Receive loop

    private func run() async {
        do {
            try await self.channel.start()
        } catch {
            SpeakLogger.logError(error, context: "Transport handshake", logger: SpeakLogger.transport)
            self.reportDisconnected()
            return
        }

        while !Task.isCancelled {
            let message: TransportMessage
            do {
                message = try await self.channel.receive()
            } catch {
                SpeakLogger.logError(error, context: "Receive frame", logger: SpeakLogger.transport)
                break
            }
            guard !Task.isCancelled, await self.handle(message) else { break }
        }

        self.channel.close()
        self.reportDisconnected()
    }

    private func reportDisconnected() {
        self.onDisconnected?()
    }

    /// Handles one message. Returns whether the connection may continue.
    private func handle(_ message: TransportMessage) async -> Bool {
        switch message {
        case .hello(let hello):
            return await self.handleHello(hello)

        case .authenticate(let auth):
            return await self.handleAuthentication(auth)

        case .ping:
            await self.send(.pong)
            return true

        default:
            guard self.isAuthenticated else {
                SpeakLogger.transport.warning("Dropping connection: session message before authentication")
                return false
            }
            return await self.handleSessionMessage(message)
        }
    }

    private func handleHello(_ hello: HelloMessage) async -> Bool {
        guard !self.isAuthenticated else { return false }
        guard hello.isProtocolVersionCompatible else {
            SpeakLogger.transport.warning(
                """
                Rejecting \(hello.deviceName, privacy: .public): protocol version mismatch \
                (client v\(hello.protocolVersion), server v\(SpeakTransportProtocolVersion))
                """
            )
            await self.send(.error(.protocolMismatch(clientVersion: hello.protocolVersion)))
            return false
        }
        self.deviceId = hello.deviceId
        self.deviceName = hello.deviceName
        SpeakLogger.transport.info("Hello from \(hello.deviceName, privacy: .public)")
        return true
    }

    private func handleAuthentication(_ auth: AuthenticateMessage) async -> Bool {
        guard !self.isAuthenticated else { return false }
        guard let deviceId = self.deviceId, let deviceName = self.deviceName else {
            SpeakLogger.transport.warning("Dropping connection: authenticate arrived before hello")
            return false
        }
        guard PairingManager.shared.validatePairingCode(auth.pairingCode) else {
            await self.send(.authResult(AuthResultMessage(success: false, errorMessage: "Invalid pairing code")))
            SpeakLogger.transport.warning("Authentication failed")
            return false
        }

        self.isAuthenticated = true
        // A paired device earns the session frame ceiling. Raise it before the
        // result goes out, so the first transcript frame cannot outrun it.
        await self.channel.admitSessionFrames()
        await self.send(.authResult(AuthResultMessage(success: true, sessionToken: UUID().uuidString)))

        guard !Task.isCancelled else { return false }
        PairingManager.shared.addPairedDevice(id: deviceId, name: deviceName)
        self.onAuthenticated?(deviceId, deviceName)

        SpeakLogger.transport.info("Authentication successful for \(deviceName, privacy: .public)")
        return true
    }

    private func handleSessionMessage(_ message: TransportMessage) async -> Bool {
        switch message {
        case .sessionStart(let session):
            self.currentSessionId = session.sessionId
            SpeakLogger.transcription.info(
                """
                Session started: \(session.sessionId, privacy: .private) \
                with model \(session.model, privacy: .public)
                """
            )

        case .transcriptChunk(let chunk):
            if chunk.isFinal {
                self.onTranscriptChunk?(chunk.sessionId, chunk.text)
            }
            await self.send(.ack(AckMessage(sequenceNumber: chunk.sequenceNumber)))

        case .sessionEnd(let end):
            SpeakLogger.transcription.info("Session ended: \(end.wordCount) words in \(end.duration)s")
            self.currentSessionId = nil

        default:
            break
        }
        return true
    }

    private func send(_ message: TransportMessage) async {
        do {
            try await self.channel.send(message)
        } catch {
            SpeakLogger.logError(error, context: "Send message", logger: SpeakLogger.transport)
        }
    }
}
#endif
