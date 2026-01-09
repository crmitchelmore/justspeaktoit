#if os(iOS)
import Foundation
import Network
import SpeakCore

// MARK: - Mac Discovery

/// Discovers available Speak instances on the local network via Bonjour.
@MainActor
public final class MacDiscovery: ObservableObject {
    @Published public private(set) var discoveredMacs: [DiscoveredMac] = []
    @Published public private(set) var isSearching = false
    
    private var browser: NWBrowser?
    
    public struct DiscoveredMac: Identifiable, Equatable {
        public let id: String
        public let name: String
        public let endpoint: NWEndpoint
        
        public init(id: String, name: String, endpoint: NWEndpoint) {
            self.id = id
            self.name = name
            self.endpoint = endpoint
        }
    }
    
    public init() {}
    
    public func startSearching() {
        guard browser == nil else { return }
        
        isSearching = true
        discoveredMacs = []
        
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        
        let browser = NWBrowser(
            for: .bonjour(type: SpeakTransportServiceType, domain: "local."),
            using: parameters
        )
        
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .failed(let error):
                    print("[MacDiscovery] Browser failed: \(error)")
                    self?.isSearching = false
                case .cancelled:
                    self?.isSearching = false
                default:
                    break
                }
            }
        }
        
        browser.browseResultsChangedHandler = { [weak self] results, changes in
            Task { @MainActor in
                self?.handleBrowseResults(results)
            }
        }
        
        browser.start(queue: .main)
        self.browser = browser
    }
    
    public func stopSearching() {
        browser?.cancel()
        browser = nil
        isSearching = false
    }
    
    private func handleBrowseResults(_ results: Set<NWBrowser.Result>) {
        discoveredMacs = results.compactMap { result -> DiscoveredMac? in
            guard case .service(let name, _, _, _) = result.endpoint else {
                return nil
            }
            return DiscoveredMac(
                id: "\(result.hashValue)",
                name: name,
                endpoint: result.endpoint
            )
        }
    }
}

// MARK: - Mac Connection

/// Manages connection to a macOS Speak instance.
@MainActor
public final class MacConnection: ObservableObject {
    public enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case authenticating
        case connected
        case error(String)
    }
    
    @Published public private(set) var state: ConnectionState = .disconnected
    @Published public private(set) var connectedMacName: String?
    
    private var connection: NWConnection?
    private var webSocketTask: URLSessionWebSocketTask?
    private var sessionToken: String?
    private var sequenceNumber = 0
    
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    
    public init() {
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }
    
    /// Connects to a discovered Mac.
    public func connect(to mac: MacDiscovery.DiscoveredMac, pairingCode: String) async throws {
        state = .connecting
        
        // Resolve endpoint to get host and port
        let connection = NWConnection(to: mac.endpoint, using: .tcp)
        
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.stateUpdateHandler = { [weak self] newState in
                Task { @MainActor in
                    switch newState {
                    case .ready:
                        continuation.resume()
                    case .failed(let error):
                        self?.state = .error(error.localizedDescription)
                        continuation.resume()
                    default:
                        break
                    }
                }
            }
            connection.start(queue: .main)
        }
        
        guard case .connecting = state else { return }
        
        // Get resolved endpoint info
        guard let path = connection.currentPath,
              let endpoint = path.remoteEndpoint,
              case .hostPort(let host, let port) = endpoint
        else {
            state = .error("Could not resolve endpoint")
            return
        }
        
        connection.cancel()
        
        // Create WebSocket connection
        let hostString: String
        switch host {
        case .ipv4(let addr):
            hostString = "\(addr)"
        case .ipv6(let addr):
            hostString = "[\(addr)]"
        case .name(let name, _):
            hostString = name
        @unknown default:
            hostString = "localhost"
        }
        
        guard let url = URL(string: "ws://\(hostString):\(port)/speak") else {
            state = .error("Invalid URL")
            return
        }
        
        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: url)
        task.resume()
        
        webSocketTask = task
        
        // Send hello
        state = .authenticating
        let hello = TransportMessage.hello(HelloMessage(
            deviceName: DeviceIdentity.deviceName,
            deviceId: DeviceIdentity.deviceId
        ))
        try await send(hello)
        
        // Send auth
        let auth = TransportMessage.authenticate(AuthenticateMessage(pairingCode: pairingCode))
        try await send(auth)
        
        // Wait for auth result
        let response = try await receive()
        
        switch response {
        case .authResult(let result):
            if result.success, let token = result.sessionToken {
                sessionToken = token
                connectedMacName = mac.name
                state = .connected
                startReceiveLoop()
            } else {
                state = .error(result.errorMessage ?? "Authentication failed")
                disconnect()
            }
        case .error(let error):
            state = .error(error.message)
            disconnect()
        default:
            state = .error("Unexpected response")
            disconnect()
        }
    }
    
    /// Disconnects from the Mac.
    public func disconnect() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        sessionToken = nil
        connectedMacName = nil
        sequenceNumber = 0
        state = .disconnected
    }
    
    /// Sends a transcript chunk to the connected Mac.
    public func sendTranscript(sessionId: String, text: String, isFinal: Bool) async throws {
        guard state == .connected else { return }
        
        sequenceNumber += 1
        let chunk = TranscriptChunkMessage(
            sessionId: sessionId,
            sequenceNumber: sequenceNumber,
            text: text,
            isFinal: isFinal
        )
        try await send(.transcriptChunk(chunk))
    }
    
    /// Notifies the Mac that a transcription session has started.
    public func sendSessionStart(sessionId: String, model: String) async throws {
        guard state == .connected else { return }
        
        sequenceNumber = 0
        let start = SessionStartMessage(sessionId: sessionId, model: model)
        try await send(.sessionStart(start))
    }
    
    /// Notifies the Mac that a transcription session has ended.
    public func sendSessionEnd(sessionId: String, finalText: String, duration: TimeInterval, wordCount: Int) async throws {
        guard state == .connected else { return }
        
        let end = SessionEndMessage(
            sessionId: sessionId,
            finalText: finalText,
            duration: duration,
            wordCount: wordCount
        )
        try await send(.sessionEnd(end))
    }
    
    // MARK: - Private
    
    private func send(_ message: TransportMessage) async throws {
        let data = try encoder.encode(message)
        try await webSocketTask?.send(.data(data))
    }
    
    private func receive() async throws -> TransportMessage {
        guard let task = webSocketTask else {
            throw URLError(.badServerResponse)
        }
        
        let message = try await task.receive()
        switch message {
        case .data(let data):
            return try decoder.decode(TransportMessage.self, from: data)
        case .string(let string):
            guard let data = string.data(using: .utf8) else {
                throw URLError(.cannotDecodeContentData)
            }
            return try decoder.decode(TransportMessage.self, from: data)
        @unknown default:
            throw URLError(.unknown)
        }
    }
    
    private func startReceiveLoop() {
        Task {
            while state == .connected {
                do {
                    let message = try await receive()
                    handleIncomingMessage(message)
                } catch {
                    if state == .connected {
                        state = .error(error.localizedDescription)
                        disconnect()
                    }
                    break
                }
            }
        }
    }
    
    private func handleIncomingMessage(_ message: TransportMessage) {
        switch message {
        case .ping:
            Task { try? await send(.pong) }
        case .ack:
            // Handle ack if needed
            break
        case .error(let error):
            state = .error(error.message)
            disconnect()
        default:
            break
        }
    }
}

// MARK: - Send to Mac View

import SwiftUI

public struct SendToMacView: View {
    @StateObject private var discovery = MacDiscovery()
    @StateObject private var connection = MacConnection()
    @State private var selectedMac: MacDiscovery.DiscoveredMac?
    @State private var pairingCode = ""
    @State private var showingPairingSheet = false
    
    public init() {}
    
    public var body: some View {
        Form {
            Section {
                switch connection.state {
                case .connected:
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        VStack(alignment: .leading) {
                            Text("Connected")
                                .font(.headline)
                            if let name = connection.connectedMacName {
                                Text(name)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Disconnect") {
                            connection.disconnect()
                        }
                        .buttonStyle(.bordered)
                    }
                    
                case .connecting, .authenticating:
                    HStack {
                        ProgressView()
                        Text(connection.state == .connecting ? "Connecting..." : "Authenticating...")
                            .padding(.leading, 8)
                    }
                    
                case .error(let message):
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text(message)
                            .foregroundStyle(.secondary)
                    }
                    
                case .disconnected:
                    Text("Not connected to a Mac")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Connection Status")
            }
            
            if case .disconnected = connection.state {
                Section {
                    if discovery.isSearching {
                        HStack {
                            ProgressView()
                            Text("Searching...")
                                .padding(.leading, 8)
                        }
                    }
                    
                    ForEach(discovery.discoveredMacs) { mac in
                        Button {
                            selectedMac = mac
                            showingPairingSheet = true
                        } label: {
                            HStack {
                                Image(systemName: "desktopcomputer")
                                Text(mac.name)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    
                    if !discovery.isSearching && discovery.discoveredMacs.isEmpty {
                        ContentUnavailableView {
                            Label("No Macs Found", systemImage: "desktopcomputer")
                        } description: {
                            Text("Make sure Speak is running on your Mac and both devices are on the same network.")
                        } actions: {
                            Button("Search Again") {
                                discovery.startSearching()
                            }
                        }
                    }
                } header: {
                    Text("Available Macs")
                }
            }
        }
        .navigationTitle("Send to Mac")
        .onAppear { discovery.startSearching() }
        .onDisappear { discovery.stopSearching() }
        .sheet(isPresented: $showingPairingSheet) {
            PairingSheet(
                macName: selectedMac?.name ?? "Mac",
                pairingCode: $pairingCode,
                onPair: {
                    guard let mac = selectedMac else { return }
                    showingPairingSheet = false
                    Task {
                        try? await connection.connect(to: mac, pairingCode: pairingCode)
                        pairingCode = ""
                    }
                },
                onCancel: {
                    showingPairingSheet = false
                    pairingCode = ""
                }
            )
        }
    }
}

struct PairingSheet: View {
    let macName: String
    @Binding var pairingCode: String
    let onPair: () -> Void
    let onCancel: () -> Void
    
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Enter the pairing code shown on \(macName)")
                        .foregroundStyle(.secondary)
                    
                    TextField("Pairing Code", text: $pairingCode)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .font(.title2.monospaced())
                        .multilineTextAlignment(.center)
                }
                
                Section {
                    Text("You can find the pairing code in Speak's settings on your Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Pair with \(macName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Pair", action: onPair)
                        .disabled(pairingCode.count < 6)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

#Preview {
    NavigationStack {
        SendToMacView()
    }
}
#endif
