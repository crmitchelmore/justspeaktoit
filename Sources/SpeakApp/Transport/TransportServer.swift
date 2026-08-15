#if os(macOS)
import Foundation
import Network
import SpeakCore

/// Advertises the Speak transport service via Bonjour and accepts connections from iOS devices.
///
/// The wire is WebSocket over TCP, built from `SpeakTransportWire` so that this
/// server and the `MacConnection` client cannot frame messages differently.
@MainActor
public final class TransportServer: ObservableObject {
    @Published public private(set) var isRunning = false
    @Published public private(set) var connectedDevices: [ConnectedDevice] = []
    @Published public private(set) var error: Error?

    /// Port the listener bound, once it is ready. Bonjour hides this from the
    /// phone; tests use it to reach the server over loopback.
    public private(set) var port: UInt16?

    public struct ConnectedDevice: Identifiable {
        public let id: String
        public let name: String
        public let connectedAt: Date
        public var lastActivity: Date

        public init(id: String, name: String, connectedAt: Date = Date()) {
            self.id = id
            self.name = name
            self.connectedAt = connectedAt
            self.lastActivity = connectedAt
        }
    }

    private var listener: NWListener?
    private var connections: [String: TransportConnection] = [:]

    /// Callback when transcript chunk received
    public var onTranscriptReceived: ((String, String) -> Void)?

    /// Callback when the server stops because of a failure.
    ///
    /// `NWListener.start(queue:)` is non-throwing, so a listener that cannot bind reports
    /// the problem asynchronously through its state handler — long after `start()` has
    /// returned successfully. Callers use this to keep their own state (e.g. the
    /// "Send to Mac" preference) in sync with reality.
    public var onFailure: ((Error) -> Void)?

    public init() {}

    /// Start advertising and accepting connections.
    public func start() throws {
        try self.start(on: .any, advertisesService: true)
    }

    /// Starts the listener on `port`.
    ///
    /// - Parameter advertisesService: Whether to publish the Bonjour record and
    ///   offer peer-to-peer interfaces. Tests bind loopback without either, so
    ///   they neither need the local network nor disturb real devices.
    func start(on port: NWEndpoint.Port, advertisesService: Bool) throws {
        guard !self.isRunning else { return }

        self.error = nil
        SpeakLogger.transport.info("Starting transport server")

        let parameters = SpeakTransportWire.parameters(includesPeerToPeer: advertisesService)

        do {
            let listener = try NWListener(using: parameters, on: port)

            if advertisesService {
                listener.service = NWListener.Service(
                    name: Host.current().localizedName ?? "Mac",
                    type: SpeakTransportServiceType
                )
            }

            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    self?.handleListenerState(state)
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    self?.handleNewConnection(connection)
                }
            }

            listener.start(queue: .main)
            self.listener = listener
            self.isRunning = true

            SpeakLogger.transport.info("Transport server listening")
        } catch {
            self.error = error
            SpeakLogger.logError(error, context: "TransportServer.start", logger: SpeakLogger.transport)
            throw error
        }
    }

    /// Stop the server and disconnect all clients.
    public func stop() {
        guard self.isRunning else { return }

        SpeakLogger.transport.info("Stopping transport server")

        self.dropEverything()
        self.listener?.cancel()
        self.listener = nil
        self.port = nil
        self.isRunning = false
    }

    /// Disconnect a specific device.
    public func disconnectDevice(id: String) {
        self.connections[id]?.disconnect()
        self.connections.removeValue(forKey: id)
        self.connectedDevices.removeAll { $0.id == id }
    }

    // MARK: - Private

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            self.port = self.listener?.port?.rawValue
            SpeakLogger.transport.info("Listener ready")
        case .failed(let error):
            SpeakLogger.logError(error, context: "Listener failed", logger: SpeakLogger.transport)
            // Tear the listener down so a later start() builds a fresh one instead of
            // leaking the dead listener. Drop live connections too: WireUp only flips
            // `enableSendToMac` off on failure, so a surviving TransportConnection would
            // keep delivering transcript chunks while the UI says Send to Mac is off.
            self.dropEverything()
            self.listener?.cancel()
            self.listener = nil
            self.port = nil
            self.error = error
            self.isRunning = false
            self.onFailure?(error)
        case .cancelled:
            self.isRunning = false
        default:
            break
        }
    }

    private func dropEverything() {
        for connection in self.connections.values {
            connection.disconnect()
        }
        self.connections.removeAll()
        self.connectedDevices.removeAll()
    }

    private func handleNewConnection(_ nwConnection: NWConnection) {
        SpeakLogger.transport.info("New connection from \(String(describing: nwConnection.endpoint))")

        let connection = TransportConnection(connection: nwConnection)

        connection.onAuthenticated = { [weak self] deviceId, deviceName in
            Task { @MainActor in
                self?.handleAuthenticated(deviceId: deviceId, deviceName: deviceName, connection: connection)
            }
        }

        connection.onTranscriptChunk = { [weak self] sessionId, text in
            Task { @MainActor in
                self?.handleTranscriptChunk(sessionId: sessionId, text: text)
            }
        }

        connection.onDisconnected = { [weak self] deviceId in
            Task { @MainActor in
                self?.handleDisconnected(deviceId: deviceId)
            }
        }

        connection.start()
    }

    private func handleAuthenticated(deviceId: String, deviceName: String, connection: TransportConnection) {
        self.connections[deviceId] = connection

        let device = ConnectedDevice(id: deviceId, name: deviceName)
        self.connectedDevices.append(device)

        SpeakLogger.transport.info(
            "Device authenticated: \(deviceName, privacy: .public) (\(deviceId, privacy: .private))"
        )
    }

    private func handleTranscriptChunk(sessionId: String, text: String) {
        // Update last activity
        if let index = self.connectedDevices.firstIndex(where: {
            self.connections[$0.id]?.currentSessionId == sessionId
        }) {
            self.connectedDevices[index].lastActivity = Date()
        }

        SpeakLogger.transcription.info(
            "Received chunk: \(text.count) chars for session \(sessionId, privacy: .private)"
        )

        // Forward to output handler
        self.onTranscriptReceived?(sessionId, text)
    }

    private func handleDisconnected(deviceId: String) {
        self.connections.removeValue(forKey: deviceId)
        self.connectedDevices.removeAll { $0.id == deviceId }

        SpeakLogger.transport.info("Device disconnected: \(deviceId, privacy: .private)")
    }
}

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
    var onDisconnected: ((String) -> Void)?

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
            guard await self.handle(message) else { break }
        }

        self.channel.close()
        self.reportDisconnected()
    }

    private func reportDisconnected() {
        guard let deviceId = self.deviceId else { return }
        self.onDisconnected?(deviceId)
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
