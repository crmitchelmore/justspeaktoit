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
    // Own channels from accept through disconnect, including unpaired peers.
    private var acceptedConnections: [UUID: TransportConnection] = [:]
    private var listenerGeneration: UUID?
    private let maximumPendingConnections: Int
    private let handshakeTimeout: Duration

    var pendingConnectionCount: Int {
        self.acceptedConnections.values.filter { !$0.isAuthenticated }.count
    }

    /// Callback when transcript chunk received
    public var onTranscriptReceived: ((String, String) -> Void)?

    /// Callback when the server stops because of a failure.
    ///
    /// `NWListener.start(queue:)` is non-throwing, so a listener that cannot bind reports
    /// the problem asynchronously through its state handler — long after `start()` has
    /// returned successfully. Callers use this to keep their own state (e.g. the
    /// "Send to Mac" preference) in sync with reality.
    public var onFailure: ((Error) -> Void)?

    public convenience init() {
        self.init(maximumPendingConnections: 8, handshakeTimeout: .seconds(10))
    }

    init(maximumPendingConnections: Int, handshakeTimeout: Duration) {
        self.maximumPendingConnections = maximumPendingConnections
        self.handshakeTimeout = handshakeTimeout
    }

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

            let generation = UUID()
            self.listenerGeneration = generation
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard self?.listenerGeneration == generation else { return }
                    self?.handleListenerState(state)
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    guard let self, self.listenerGeneration == generation, self.isRunning else {
                        connection.cancel()
                        return
                    }
                    self.handleNewConnection(connection)
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

        self.listenerGeneration = nil
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
            self.listenerGeneration = nil
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
        let accepted = self.acceptedConnections.values
        self.acceptedConnections.removeAll()
        self.connections.removeAll()
        for connection in accepted {
            connection.disconnect()
        }
        self.connectedDevices.removeAll()
    }

    private func handleNewConnection(_ nwConnection: NWConnection) {
        SpeakLogger.transport.info("New connection from \(String(describing: nwConnection.endpoint))")

        guard self.pendingConnectionCount < self.maximumPendingConnections else {
            nwConnection.cancel()
            return
        }
        let connection = TransportConnection(connection: nwConnection, handshakeTimeout: self.handshakeTimeout)
        let connectionID = UUID()
        self.acceptedConnections[connectionID] = connection

        connection.onAuthenticated = { [weak self, weak connection] deviceId, deviceName in
            guard let self, let connection, self.isRunning,
                  self.acceptedConnections[connectionID] === connection else { return }
            self.handleAuthenticated(deviceId: deviceId, deviceName: deviceName, connection: connection)
        }

        connection.onTranscriptChunk = { [weak self, weak connection] sessionId, text in
            guard let self, let connection, self.isRunning,
                  self.acceptedConnections[connectionID] === connection else { return }
            self.handleTranscriptChunk(sessionId: sessionId, text: text)
        }

        connection.onDisconnected = { [weak self, weak connection] in
            guard let self, let connection else { return }
            self.acceptedConnections.removeValue(forKey: connectionID)
            self.handleDisconnected(connection: connection)
        }

        connection.start()
    }

    private func handleAuthenticated(deviceId: String, deviceName: String, connection: TransportConnection) {
        // A reconnect replaces the previous channel. Its eventual disconnect
        // callback must not remove the newly authenticated device.
        if let previous = self.connections[deviceId], previous !== connection {
            previous.disconnect()
        }
        self.connections[deviceId] = connection
        self.connectedDevices.removeAll { $0.id == deviceId }

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

    private func handleDisconnected(connection: TransportConnection) {
        let deviceIds = self.connections.compactMap { $0.value === connection ? $0.key : nil }
        for deviceId in deviceIds {
            self.connections.removeValue(forKey: deviceId)
            self.connectedDevices.removeAll { $0.id == deviceId }
            SpeakLogger.transport.info("Device disconnected: \(deviceId, privacy: .private)")
        }
    }
}

#endif
