#if os(macOS)
import Foundation
import Network
import SpeakCore

/// Advertises the Speak transport service via Bonjour and accepts connections from iOS devices.
@MainActor
public final class TransportServer: ObservableObject {
    @Published public private(set) var isRunning = false
    @Published public private(set) var connectedDevices: [ConnectedDevice] = []
    @Published public private(set) var error: Error?
    
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
    private let pairingManager = PairingManager.shared
    
    /// Callback when transcript chunk received
    public var onTranscriptReceived: ((String, String) -> Void)?
    
    public init() {}
    
    /// Start advertising and accepting connections.
    public func start() throws {
        guard !isRunning else { return }
        
        SpeakLogger.transport.info("Starting transport server")
        
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        
        // Advertise Bonjour service
        let service = NWListener.Service(
            name: Host.current().localizedName ?? "Mac",
            type: SpeakTransportServiceType
        )
        
        do {
            let listener = try NWListener(service: service, using: parameters)
            
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
            isRunning = true
            
            SpeakLogger.transport.info("Transport server listening on Bonjour")
        } catch {
            SpeakLogger.logError(error, context: "TransportServer.start", logger: SpeakLogger.transport)
            throw error
        }
    }
    
    /// Stop the server and disconnect all clients.
    public func stop() {
        guard isRunning else { return }
        
        SpeakLogger.transport.info("Stopping transport server")
        
        // Disconnect all clients
        for connection in connections.values {
            connection.disconnect()
        }
        connections.removeAll()
        connectedDevices.removeAll()
        
        listener?.cancel()
        listener = nil
        isRunning = false
    }
    
    /// Disconnect a specific device.
    public func disconnectDevice(id: String) {
        connections[id]?.disconnect()
        connections.removeValue(forKey: id)
        connectedDevices.removeAll { $0.id == id }
    }
    
    // MARK: - Private
    
    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            SpeakLogger.transport.info("Listener ready")
        case .failed(let error):
            SpeakLogger.logError(error, context: "Listener failed", logger: SpeakLogger.transport)
            self.error = error
            isRunning = false
        case .cancelled:
            isRunning = false
        default:
            break
        }
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
        connections[deviceId] = connection
        
        let device = ConnectedDevice(id: deviceId, name: deviceName)
        connectedDevices.append(device)
        
        SpeakLogger.transport.info("Device authenticated: \(deviceName, privacy: .public) (\(deviceId, privacy: .private))")
    }
    
    private func handleTranscriptChunk(sessionId: String, text: String) {
        // Update last activity
        if let index = connectedDevices.firstIndex(where: { connections[$0.id]?.currentSessionId == sessionId }) {
            connectedDevices[index].lastActivity = Date()
        }
        
        SpeakLogger.transcription.info("Received chunk: \(text.count) chars for session \(sessionId, privacy: .private)")
        
        // Forward to output handler
        onTranscriptReceived?(sessionId, text)
    }
    
    private func handleDisconnected(deviceId: String) {
        connections.removeValue(forKey: deviceId)
        connectedDevices.removeAll { $0.id == deviceId }
        
        SpeakLogger.transport.info("Device disconnected: \(deviceId, privacy: .private)")
    }
}

// MARK: - Individual Connection Handler

@MainActor
final class TransportConnection {
    private let connection: NWConnection
    private var isAuthenticated = false
    private var deviceId: String?
    private var deviceName: String?
    private(set) var currentSessionId: String?
    
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    
    var onAuthenticated: ((String, String) -> Void)?
    var onTranscriptChunk: ((String, String) -> Void)?
    var onDisconnected: ((String) -> Void)?
    
    init(connection: NWConnection) {
        self.connection = connection
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }
    
    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.handleState(state)
            }
        }
        connection.start(queue: .main)
        startReceiving()
    }
    
    func disconnect() {
        connection.cancel()
    }
    
    private func handleState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            SpeakLogger.transport.debug("Connection ready")
        case .failed(let error):
            SpeakLogger.logError(error, context: "Connection failed", logger: SpeakLogger.transport)
            if let deviceId {
                onDisconnected?(deviceId)
            }
        case .cancelled:
            if let deviceId {
                onDisconnected?(deviceId)
            }
        default:
            break
        }
    }
    
    private func startReceiving() {
        // Receive length prefix (4 bytes)
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            
            if let error {
                SpeakLogger.logError(error, context: "Receive length", logger: SpeakLogger.transport)
                return
            }
            
            guard let data, data.count == 4 else { return }
            
            let length = data.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            
            // Receive message
            self.connection.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { messageData, _, _, error in
                Task { @MainActor in
                    if let error {
                        SpeakLogger.logError(error, context: "Receive message", logger: SpeakLogger.transport)
                        return
                    }
                    
                    guard let messageData else { return }
                    
                    await self.handleMessage(messageData)
                    
                    // Continue receiving
                    if !isComplete {
                        self.startReceiving()
                    }
                }
            }
        }
    }
    
    private func handleMessage(_ data: Data) async {
        do {
            let message = try decoder.decode(TransportMessage.self, from: data)
            
            switch message {
            case .hello(let hello):
                deviceId = hello.deviceId
                deviceName = hello.deviceName
                SpeakLogger.transport.info("Hello from \(hello.deviceName, privacy: .public)")
                
            case .authenticate(let auth):
                await handleAuthentication(auth)
                
            case .sessionStart(let session):
                currentSessionId = session.sessionId
                SpeakLogger.transcription.info("Session started: \(session.sessionId, privacy: .private) with model \(session.model, privacy: .public)")
                
            case .transcriptChunk(let chunk):
                if chunk.isFinal {
                    onTranscriptChunk?(chunk.sessionId, chunk.text)
                }
                await sendAck(chunk.sequenceNumber)
                
            case .sessionEnd(let end):
                SpeakLogger.transcription.info("Session ended: \(end.wordCount) words in \(end.duration)s")
                currentSessionId = nil
                
            case .ping:
                await send(.pong)
                
            default:
                break
            }
        } catch {
            SpeakLogger.logError(error, context: "Decode message", logger: SpeakLogger.transport)
        }
    }
    
    private func handleAuthentication(_ auth: AuthenticateMessage) async {
        let isValid = PairingManager.shared.validatePairingCode(auth.pairingCode)
        
        if isValid, let deviceId, let deviceName {
            isAuthenticated = true
            
            let token = UUID().uuidString
            let result = AuthResultMessage(success: true, sessionToken: token)
            await send(.authResult(result))
            
            PairingManager.shared.addPairedDevice(id: deviceId, name: deviceName)
            onAuthenticated?(deviceId, deviceName)
            
            SpeakLogger.transport.info("Authentication successful for \(deviceName, privacy: .public)")
        } else {
            let result = AuthResultMessage(success: false, errorMessage: "Invalid pairing code")
            await send(.authResult(result))
            
            SpeakLogger.transport.warning("Authentication failed")
            connection.cancel()
        }
    }
    
    private func sendAck(_ sequenceNumber: Int) async {
        await send(.ack(AckMessage(sequenceNumber: sequenceNumber)))
    }
    
    private func send(_ message: TransportMessage) async {
        do {
            let data = try encoder.encode(message)
            
            // Send length prefix
            var length = UInt32(data.count).bigEndian
            let lengthData = withUnsafeBytes(of: &length) { Data($0) }
            
            connection.send(content: lengthData, completion: .contentProcessed { _ in })
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    SpeakLogger.logError(error, context: "Send message", logger: SpeakLogger.transport)
                }
            })
        } catch {
            SpeakLogger.logError(error, context: "Encode message", logger: SpeakLogger.transport)
        }
    }
}
#endif
