// swiftlint:disable file_length
#if os(iOS)
import Foundation
import MultipeerConnectivity
import Network
import SpeakCore

// MARK: - Mac Discovery

/// Discovers available Speak instances on the local network via Multipeer Connectivity.
@MainActor
public final class MacDiscovery: NSObject, ObservableObject {
    public static let shared = MacDiscovery()

    @Published public private(set) var discoveredMacs: [DiscoveredMac] = []
    @Published public private(set) var isSearching = false
    @Published public private(set) var errorMessage: String?

    let localPeerID: MCPeerID
    private var browser: MCNearbyServiceBrowser?

    public struct DiscoveredMac: Identifiable, Equatable {
        public let id: String
        public let name: String
        public let endpoint: NWEndpoint
        public let peerID: MCPeerID

        public init(id: String, name: String, endpoint: NWEndpoint) {
            self.id = id
            self.name = name
            self.endpoint = endpoint
            self.peerID = MCPeerID(displayName: name)
        }

        public init(id: String, name: String, endpoint: NWEndpoint, peerID: MCPeerID) {
            self.id = id
            self.name = name
            self.endpoint = endpoint
            self.peerID = peerID
        }

        public static func == (lhs: DiscoveredMac, rhs: DiscoveredMac) -> Bool {
            lhs.id == rhs.id && lhs.peerID == rhs.peerID
        }
    }

    public override init() {
        self.localPeerID = MCPeerID(displayName: DeviceIdentity.deviceName)
        super.init()
    }

    public func startSearching() {
        guard browser == nil else { return }

        errorMessage = nil
        isSearching = true

        let browser = MCNearbyServiceBrowser(peer: localPeerID, serviceType: SpeakTransportServiceType)
        browser.delegate = self
        browser.startBrowsingForPeers()
        self.browser = browser
    }

    public func stopSearching() {
        browser?.stopBrowsingForPeers()
        browser?.delegate = nil
        browser = nil
        isSearching = false
    }

    public func invite(
        _ mac: DiscoveredMac,
        to session: MCSession,
        context: Data,
        timeout: TimeInterval = 30
    ) {
        if browser == nil {
            startSearching()
        }
        browser?.invitePeer(mac.peerID, to: session, withContext: context, timeout: timeout)
    }

    private func upsert(peerID: MCPeerID, discoveryInfo: [String: String]?) {
        let id = discoveryInfo?["deviceID"] ?? peerID.displayName
        let name = discoveryInfo?["deviceName"] ?? peerID.displayName
        let endpoint = NWEndpoint.service(
            name: name,
            type: SpeakTransportBonjourTCPService,
            domain: "local.",
            interface: nil
        )
        let mac = DiscoveredMac(id: id, name: name, endpoint: endpoint, peerID: peerID)

        if let index = discoveredMacs.firstIndex(where: { $0.id == id || $0.peerID == peerID }) {
            discoveredMacs[index] = mac
        } else {
            discoveredMacs.append(mac)
        }
    }

    private func remove(peerID: MCPeerID) {
        discoveredMacs.removeAll { $0.peerID == peerID }
    }
}

extension MacDiscovery: MCNearbyServiceBrowserDelegate {
    nonisolated public func browser(
        _ browser: MCNearbyServiceBrowser,
        foundPeer peerID: MCPeerID,
        withDiscoveryInfo info: [String: String]?
    ) {
        Task { @MainActor [weak self] in
            self?.upsert(peerID: peerID, discoveryInfo: info)
        }
    }

    nonisolated public func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor [weak self] in
            self?.remove(peerID: peerID)
        }
    }

    nonisolated public func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        Task { @MainActor [weak self] in
            self?.errorMessage = error.localizedDescription
            self?.isSearching = false
        }
    }
}

// MARK: - Mac Connection

/// Manages connection to a macOS Speak instance.
@MainActor
public final class MacConnection: NSObject, ObservableObject {
    public static let shared = MacConnection()

    public enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case authenticating
        case connected
        case error(String)
    }

    @Published public private(set) var state: ConnectionState = .disconnected
    @Published public private(set) var connectedMacName: String?
    public weak var historyTransportDelegate: HistoryTransportDelegate? {
        didSet {
            guard state == .connected else { return }
            Task { [weak self] in
                await self?.exchangeHistorySnapshot()
            }
        }
    }

    private struct PendingConnection {
        let peerID: MCPeerID
        let macName: String
        let continuation: CheckedContinuation<Void, Error>
        let timeoutTask: Task<Void, Never>
    }

    private let localPeerID: MCPeerID
    private let session: MCSession
    private let discovery: MacDiscovery
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var connectedPeer: MCPeerID?
    private var pendingConnection: PendingConnection?
    private var sequenceNumber = 0
    private var historyBatchAccumulator = HistoryBatchAccumulator()

    public override convenience init() {
        self.init(discovery: .shared)
    }

    public init(discovery: MacDiscovery) {
        self.discovery = discovery
        self.localPeerID = discovery.localPeerID
        self.session = MCSession(peer: localPeerID, securityIdentity: nil, encryptionPreference: .required)
        super.init()
        self.session.delegate = self
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    /// Connects to a discovered Mac using an encrypted MPC invitation context.
    public func connect(to mac: MacDiscovery.DiscoveredMac, pairingCode: String) async throws {
        guard pendingConnection == nil else {
            throw MacConnectionError.connectionInProgress
        }

        state = .authenticating
        connectedMacName = nil
        connectedPeer = nil

        let context = PairingInvitationContext(
            deviceID: DeviceIdentity.deviceId,
            deviceName: DeviceIdentity.deviceName,
            pairingCode: pairingCode
        )
        let contextData = try encoder.encode(context)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let timeoutTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(31))
                } catch {
                    return
                }
                await MainActor.run {
                    self?.failPendingConnection(
                        for: mac.peerID,
                        message: "Pairing timed out. Check the code and make sure the Mac is still advertising."
                    )
                }
            }

            pendingConnection = PendingConnection(
                peerID: mac.peerID,
                macName: mac.name,
                continuation: continuation,
                timeoutTask: timeoutTask
            )
            discovery.invite(mac, to: session, context: contextData)
        }
    }

    /// Disconnects from the Mac.
    public func disconnect() {
        failPendingConnection(message: "Pairing cancelled.")
        session.disconnect()
        connectedPeer = nil
        connectedMacName = nil
        sequenceNumber = 0
        historyBatchAccumulator.removeAll()
        state = .disconnected
    }

    public func markTransportError(_ error: Error) {
        failPendingConnection(message: error.localizedDescription)
        session.disconnect()
        connectedPeer = nil
        connectedMacName = nil
        sequenceNumber = 0
        historyBatchAccumulator.removeAll()
        state = .error(error.localizedDescription)
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
        try send(.transcriptChunk(chunk))
    }

    /// Notifies the Mac that a transcription session has started.
    public func sendSessionStart(sessionId: String, model: String) async throws {
        guard state == .connected else { return }

        sequenceNumber = 0
        let start = SessionStartMessage(sessionId: sessionId, model: model)
        try send(.sessionStart(start))
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
        try send(.sessionEnd(end))
    }

    private func send(_ message: TransportMessage) throws {
        guard let connectedPeer else { return }
        let data = try encoder.encode(message)
        try session.send(data, toPeers: [connectedPeer], with: .reliable)
    }

    private func handleConnected(peerID: MCPeerID) {
        guard let pending = pendingConnection, pending.peerID == peerID else {
            session.cancelConnectPeer(peerID)
            return
        }
        connectedPeer = peerID
        connectedMacName = pending.macName
        state = .connected
        completePendingConnection(for: peerID)
        Task { [weak self] in
            await self?.exchangeHistorySnapshot()
        }
    }

    private func handleDisconnected(peerID: MCPeerID) {
        if pendingConnection?.peerID == peerID {
            failPendingConnection(for: peerID, message: "Pairing was rejected by the Mac.")
            return
        }
        guard connectedPeer == peerID else { return }
        connectedPeer = nil
        connectedMacName = nil
        sequenceNumber = 0
        historyBatchAccumulator.removeAll()
        state = .disconnected
    }

    private func completePendingConnection(for peerID: MCPeerID) {
        guard let pending = pendingConnection, pending.peerID == peerID else { return }
        pending.timeoutTask.cancel()
        pendingConnection = nil
        pending.continuation.resume()
    }

    private func failPendingConnection(for peerID: MCPeerID, message: String) {
        guard let pending = pendingConnection, pending.peerID == peerID else { return }
        failPendingConnection(pending, message: message)
    }

    private func failPendingConnection(message: String) {
        guard let pending = pendingConnection else { return }
        failPendingConnection(pending, message: message)
    }

    private func failPendingConnection(_ pending: PendingConnection, message: String) {
        pending.timeoutTask.cancel()
        pendingConnection = nil
        state = .error(message)
        pending.continuation.resume(throwing: MacConnectionError.pairingFailed(message))
    }

    private func handleIncomingMessage(_ message: TransportMessage) {
        switch message {
        case .ping:
            Task { [weak self] in
                try? await self?.sendPong()
            }
        case .historySyncRequest(let request):
            Task { [weak self] in
                try? await self?.sendHistorySnapshot(requestID: request.requestID)
            }
        case .historySyncBatch(let batch):
            guard let assembled = historyBatchAccumulator.append(batch) else { break }
            Task { [weak self] in
                guard let self else { return }
                await self.historyTransportDelegate?.applyHistoryBatch(
                    entries: assembled.snapshot.entries,
                    tombstones: assembled.snapshot.tombstones
                )
                try? self.send(
                    .historySyncComplete(
                        HistorySyncCompleteMessage(
                            requestID: assembled.requestID,
                            receivedBatchCount: assembled.receivedBatchCount
                        )
                    )
                )
            }
        case .historySyncComplete:
            break
        case .ack:
            break
        case .error(let error):
            state = .error(error.message)
        default:
            break
        }
    }

    private func sendPong() async throws {
        try send(.pong)
    }

    public func broadcastHistoryDelta(
        entries: [SyncableHistoryEntry],
        tombstones: [HistoryDeletionTombstone]
    ) async {
        guard state == .connected else { return }
        let requestID = UUID()
        let batches = HistorySyncBatchMessage.batches(
            requestID: requestID,
            entries: entries,
            tombstones: tombstones
        )
        for batch in batches {
            try? send(.historySyncBatch(batch))
        }
    }

    private func exchangeHistorySnapshot() async {
        let request = HistorySyncRequestMessage()
        try? send(.historySyncRequest(request))
    }

    private func sendHistorySnapshot(requestID: UUID) throws {
        guard let historyTransportDelegate else { return }
        let snapshot = historyTransportDelegate.historySnapshot(maxEntries: SpeakTransportHistoryMaxSnapshotEntries)
        let batches = HistorySyncBatchMessage.batches(
            requestID: requestID,
            entries: snapshot.entries,
            tombstones: snapshot.tombstones
        )
        for batch in batches {
            try send(.historySyncBatch(batch))
        }
    }
}

public enum MacConnectionError: LocalizedError, Equatable {
    case connectionInProgress
    case pairingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .connectionInProgress:
            return "A pairing attempt is already in progress."
        case .pairingFailed(let message):
            return message
        }
    }
}

extension MacConnection: MCSessionDelegate {
    nonisolated public func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch state {
            case .connected:
                self.handleConnected(peerID: peerID)
            case .connecting:
                self.state = .connecting
            case .notConnected:
                self.handleDisconnected(peerID: peerID)
            @unknown default:
                self.state = .error("Unknown connection state")
            }
        }
    }

    nonisolated public func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard peerID == self.connectedPeer else { return }
            do {
                let message = try self.decoder.decode(TransportMessage.self, from: data)
                self.handleIncomingMessage(message)
            } catch {
                self.state = .error(error.localizedDescription)
            }
        }
    }

    nonisolated public func session(
        _ session: MCSession,
        didReceive stream: InputStream,
        withName streamName: String,
        fromPeer peerID: MCPeerID
    ) {}

    nonisolated public func session(
        _ session: MCSession,
        didStartReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        with progress: Progress
    ) {}

    nonisolated public func session(
        _ session: MCSession,
        didFinishReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        at localURL: URL?,
        withError error: Error?
    ) {}
}

// MARK: - Send to Mac View

import SwiftUI

public struct SendToMacView: View {
    @ObservedObject private var discovery = MacDiscovery.shared
    @ObservedObject private var connection = MacConnection.shared
    @State private var selectedMac: MacDiscovery.DiscoveredMac?
    @State private var pairingCode = ""
    @State private var pairingError: String?
    @State private var showingPairingSheet = false
    @State private var isPairing = false

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
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                            Text(message)
                                .foregroundStyle(.secondary)
                        }
                        Button("Try Again") {
                            connection.disconnect()
                            discovery.startSearching()
                        }
                        .buttonStyle(.bordered)
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

                    if let error = discovery.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }

                    ForEach(discovery.discoveredMacs) { mac in
                        Button {
                            selectedMac = mac
                            pairingError = nil
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
        .sheet(isPresented: $showingPairingSheet) {
            PairingSheet(
                macName: selectedMac?.name ?? "Mac",
                pairingCode: $pairingCode,
                pairingError: pairingError,
                isPairing: isPairing,
                onPair: pairWithSelectedMac,
                onCancel: {
                    showingPairingSheet = false
                    pairingCode = ""
                    pairingError = nil
                }
            )
        }
    }

    private func pairWithSelectedMac() {
        guard let mac = selectedMac else { return }
        pairingError = nil
        isPairing = true
        Task {
            do {
                try await connection.connect(to: mac, pairingCode: pairingCode)
                pairingCode = ""
                showingPairingSheet = false
            } catch {
                pairingError = error.localizedDescription
            }
            isPairing = false
        }
    }
}

struct PairingSheet: View {
    let macName: String
    @Binding var pairingCode: String
    let pairingError: String?
    let isPairing: Bool
    let onPair: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Enter the pairing code shown on \(macName)")
                        .foregroundStyle(.secondary)

                    TextField("ABCDE-FGHIJ", text: $pairingCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .textContentType(.oneTimeCode)
                        .font(.title2.monospaced())
                        .multilineTextAlignment(.center)
                        .onChange(of: pairingCode) { _, newValue in
                            pairingCode = formatPairingCode(newValue)
                        }

                    if let pairingError {
                        Label(pairingError, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Text(
                        "On your Mac, open Speak Settings → Send to Mac, then copy or type the "
                            + "ten-character pairing code. Codes expire and rotate after pairing."
                    )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Pair with \(macName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                        .disabled(isPairing)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isPairing ? "Pairing..." : "Pair", action: onPair)
                        .disabled(PairingManager.normalizedPairingCode(pairingCode).count < 10 || isPairing)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func formatPairingCode(_ rawValue: String) -> String {
        let normalised = String(PairingManager.normalizedPairingCode(rawValue).prefix(10))
        guard normalised.count > 5 else { return normalised }
        let splitIndex = normalised.index(normalised.startIndex, offsetBy: 5)
        return String(normalised[..<splitIndex]) + "-" + String(normalised[splitIndex...])
    }
}

#Preview {
    NavigationStack {
        SendToMacView()
    }
}
#endif
