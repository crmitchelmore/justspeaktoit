// swiftlint:disable file_length
#if os(macOS)
import Foundation
import MultipeerConnectivity
import SpeakCore

/// Advertises the Speak transport service via Bonjour/MPC and accepts encrypted iOS connections.
@MainActor
// swiftlint:disable:next type_body_length
public final class TransportServer: NSObject, ObservableObject {
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

    private struct AuthenticatedPeer {
        let deviceId: String
        let deviceName: String
        var currentSessionId: String?
    }

    private let localPeerID: MCPeerID
    private let session: MCSession
    private let pairingManager: PairingManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var advertiser: MCNearbyServiceAdvertiser?
    private var pendingPeers: [MCPeerID: PairingInvitationContext] = [:]
    private var authenticatedPeers: [MCPeerID: AuthenticatedPeer] = [:]
    private var historyBatchAccumulators: [MCPeerID: HistoryBatchAccumulator] = [:]
    private var failedInvitations: [String: [Date]] = [:]
    private var globalFailedInvitations: [Date] = []

    private let failedInvitationWindow: TimeInterval = 5 * 60
    private let maximumFailedInvitations = 5
    private let maximumGlobalFailedInvitations = 20

    /// Callback when transcript chunk received.
    public var onTranscriptReceived: ((String, String) -> Void)?
    public weak var historyTransportDelegate: HistoryTransportDelegate?

    public override convenience init() {
        self.init(pairingManager: .shared)
    }

    init(pairingManager: PairingManager) {
        self.localPeerID = MCPeerID(displayName: DeviceIdentity.deviceName)
        self.session = MCSession(peer: localPeerID, securityIdentity: nil, encryptionPreference: .required)
        self.pairingManager = pairingManager
        super.init()
        self.session.delegate = self
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    /// Start advertising and accepting encrypted connections.
    public func start() throws {
        guard !isRunning else { return }
        guard isValidSpeakTransportServiceType(SpeakTransportServiceType) else {
            throw TransportServerError.invalidServiceType(SpeakTransportServiceType)
        }

        SpeakLogger.transport.info("Starting transport server")

        let advertiser = MCNearbyServiceAdvertiser(
            peer: localPeerID,
            discoveryInfo: [
                "deviceID": DeviceIdentity.deviceId,
                "deviceName": DeviceIdentity.deviceName,
                "protocolVersion": "\(SpeakTransportProtocolVersion)"
            ],
            serviceType: SpeakTransportServiceType
        )
        advertiser.delegate = self
        advertiser.startAdvertisingPeer()
        self.advertiser = advertiser
        self.error = nil
        self.isRunning = true

        SpeakLogger.transport.info("Transport server advertising via MPC")
    }

    /// Stop the server and disconnect all clients.
    public func stop() {
        SpeakLogger.transport.info("Stopping transport server")

        advertiser?.stopAdvertisingPeer()
        advertiser?.delegate = nil
        advertiser = nil
        session.disconnect()
        pendingPeers.removeAll()
        authenticatedPeers.removeAll()
        historyBatchAccumulators.removeAll()
        connectedDevices.removeAll()
        isRunning = false
    }

    /// Disconnect a specific device.
    public func disconnectDevice(id: String) {
        guard let peer = authenticatedPeers.first(where: { $0.value.deviceId == id })?.key else { return }
        authenticatedPeers.removeValue(forKey: peer)
        pendingPeers.removeValue(forKey: peer)
        historyBatchAccumulators.removeValue(forKey: peer)
        connectedDevices.removeAll { $0.id == id }
        session.cancelConnectPeer(peer)
    }

    private func handleInvitation(
        from peerID: MCPeerID,
        context data: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        let rejectionKey = invitationRejectionKey(peerID: peerID, contextData: data)
        guard !isRateLimited(rejectionKey) else {
            SpeakLogger.transport.warning("Rejected rate-limited pairing invitation")
            invitationHandler(false, nil)
            return
        }

        do {
            guard let data else {
                recordFailedInvitation(rejectionKey)
                invitationHandler(false, nil)
                return
            }

            let context = try decoder.decode(PairingInvitationContext.self, from: data)
            guard validate(context: context) else {
                recordFailedInvitation(context.deviceID.isEmpty ? rejectionKey : context.deviceID)
                invitationHandler(false, nil)
                return
            }

            pendingPeers[peerID] = context
            invitationHandler(true, session)
        } catch {
            recordFailedInvitation(rejectionKey)
            SpeakLogger.logError(error, context: "Decode pairing invitation", logger: SpeakLogger.transport)
            invitationHandler(false, nil)
        }
    }

    private func validate(context: PairingInvitationContext) -> Bool {
        guard context.protocolVersion == SpeakTransportProtocolVersion else { return false }
        guard context.isFresh() else { return false }
        guard !context.deviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard !context.deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return pairingManager.validatePairingCode(context.pairingCode)
    }

    private func handleConnected(peerID: MCPeerID) {
        guard let context = pendingPeers.removeValue(forKey: peerID) else {
            session.cancelConnectPeer(peerID)
            return
        }

        authenticatedPeers[peerID] = AuthenticatedPeer(
            deviceId: context.deviceID,
            deviceName: context.deviceName,
            currentSessionId: nil
        )
        pairingManager.addPairedDevice(id: context.deviceID, name: context.deviceName)
        pairingManager.rotateAfterSuccessfulPairing()
        clearFailedInvitations(for: context.deviceID)
        globalFailedInvitations.removeAll()

        if !connectedDevices.contains(where: { $0.id == context.deviceID }) {
            connectedDevices.append(ConnectedDevice(id: context.deviceID, name: context.deviceName))
        }

        let deviceName = context.deviceName
        let deviceID = context.deviceID
        SpeakLogger.transport.info(
            "Device authenticated: \(deviceName, privacy: .public) (\(deviceID, privacy: .private))"
        )
        Task { [weak self] in
            await self?.exchangeHistorySnapshot(with: peerID)
        }
    }

    private func handleDisconnected(peerID: MCPeerID) {
        pendingPeers.removeValue(forKey: peerID)
        historyBatchAccumulators.removeValue(forKey: peerID)
        guard let peer = authenticatedPeers.removeValue(forKey: peerID) else { return }
        connectedDevices.removeAll { $0.id == peer.deviceId }
        SpeakLogger.transport.info("Device disconnected: \(peer.deviceId, privacy: .private)")
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func handleMessage(_ data: Data, from peerID: MCPeerID) async {
        do {
            guard authenticatedPeers[peerID] != nil else {
                await send(.error(.authenticationFailed), to: peerID)
                return
            }

            let message = try decoder.decode(TransportMessage.self, from: data)
            switch message {
            case .sessionStart(let session):
                authenticatedPeers[peerID]?.currentSessionId = session.sessionId
                markActivity(for: peerID)
                let sessionID = session.sessionId
                let model = session.model
                SpeakLogger.transcription.info(
                    "Started \(sessionID, privacy: .private), model \(model, privacy: .public)"
                )

            case .transcriptChunk(let chunk):
                markActivity(for: peerID)
                let characterCount = chunk.text.count
                let sessionID = chunk.sessionId
                SpeakLogger.transcription.info(
                    "Received \(characterCount) chars for \(sessionID, privacy: .private)"
                )
                onTranscriptReceived?(chunk.sessionId, chunk.text)
                await send(.ack(AckMessage(sequenceNumber: chunk.sequenceNumber)), to: peerID)

            case .sessionEnd(let end):
                authenticatedPeers[peerID]?.currentSessionId = nil
                markActivity(for: peerID)
                SpeakLogger.transcription.info("Session ended: \(end.wordCount) words in \(end.duration)s")

            case .ping:
                await send(.pong, to: peerID)

            case .historySyncRequest(let request):
                markActivity(for: peerID)
                await sendHistorySnapshot(to: peerID, requestID: request.requestID)

            case .historySyncBatch(let batch):
                markActivity(for: peerID)
                var accumulator = historyBatchAccumulators[peerID] ?? HistoryBatchAccumulator()
                let assembled = accumulator.append(batch)
                historyBatchAccumulators[peerID] = accumulator
                guard let assembled else { break }
                await historyTransportDelegate?.applyHistoryBatch(
                    entries: assembled.snapshot.entries,
                    tombstones: assembled.snapshot.tombstones
                )
                await send(
                    .historySyncComplete(
                        HistorySyncCompleteMessage(
                            requestID: assembled.requestID,
                            receivedBatchCount: assembled.receivedBatchCount
                        )
                    ),
                    to: peerID
                )

            case .historySyncComplete:
                markActivity(for: peerID)

            case .unknown(let type):
                SpeakLogger.transport.debug("Ignored unknown transport message: \(type, privacy: .public)")

            default:
                break
            }
        } catch {
            SpeakLogger.logError(error, context: "Decode message", logger: SpeakLogger.transport)
        }
    }

    private func markActivity(for peerID: MCPeerID) {
        guard let peer = authenticatedPeers[peerID],
              let index = connectedDevices.firstIndex(where: { $0.id == peer.deviceId })
        else {
            return
        }
        connectedDevices[index].lastActivity = Date()
    }

    private func send(_ message: TransportMessage, to peerID: MCPeerID) async {
        do {
            let data = try encoder.encode(message)
            try session.send(data, toPeers: [peerID], with: .reliable)
        } catch {
            SpeakLogger.logError(error, context: "Send message", logger: SpeakLogger.transport)
        }
    }

    public func broadcastHistoryDelta(
        entries: [SyncableHistoryEntry],
        tombstones: [HistoryDeletionTombstone]
    ) async {
        guard !authenticatedPeers.isEmpty else { return }
        let requestID = UUID()
        let batches = HistorySyncBatchMessage.batches(
            requestID: requestID,
            entries: entries,
            tombstones: tombstones
        )
        for peerID in authenticatedPeers.keys {
            for batch in batches {
                await send(.historySyncBatch(batch), to: peerID)
            }
        }
    }

    private func exchangeHistorySnapshot(with peerID: MCPeerID) async {
        let request = HistorySyncRequestMessage()
        await send(.historySyncRequest(request), to: peerID)
    }

    private func sendHistorySnapshot(to peerID: MCPeerID, requestID: UUID) async {
        guard let historyTransportDelegate else { return }
        let snapshot = historyTransportDelegate.historySnapshot(maxEntries: SpeakTransportHistoryMaxSnapshotEntries)
        let batches = HistorySyncBatchMessage.batches(
            requestID: requestID,
            entries: snapshot.entries,
            tombstones: snapshot.tombstones
        )
        for batch in batches {
            await send(.historySyncBatch(batch), to: peerID)
        }
    }

    private func invitationRejectionKey(peerID: MCPeerID, contextData: Data?) -> String {
        guard let contextData,
              let context = try? decoder.decode(PairingInvitationContext.self, from: contextData),
              !context.deviceID.isEmpty
        else {
            return peerID.displayName
        }
        return context.deviceID
    }

    private func isRateLimited(_ key: String) -> Bool {
        pruneFailedInvitations(for: key)
        pruneGlobalFailedInvitations()
        return (failedInvitations[key]?.count ?? 0) >= maximumFailedInvitations
            || globalFailedInvitations.count >= maximumGlobalFailedInvitations
    }

    private func recordFailedInvitation(_ key: String) {
        pruneFailedInvitations(for: key)
        pruneGlobalFailedInvitations()
        failedInvitations[key, default: []].append(Date())
        globalFailedInvitations.append(Date())
    }

    private func clearFailedInvitations(for key: String) {
        failedInvitations.removeValue(forKey: key)
    }

    private func pruneFailedInvitations(for key: String) {
        let cutoff = Date().addingTimeInterval(-failedInvitationWindow)
        failedInvitations[key] = failedInvitations[key, default: []].filter { $0 >= cutoff }
        if failedInvitations[key]?.isEmpty == true {
            failedInvitations.removeValue(forKey: key)
        }
    }

    private func pruneGlobalFailedInvitations() {
        let cutoff = Date().addingTimeInterval(-failedInvitationWindow)
        globalFailedInvitations.removeAll { $0 < cutoff }
    }
}

public enum TransportServerError: LocalizedError, Equatable {
    case invalidServiceType(String)

    public var errorDescription: String? {
        switch self {
        case .invalidServiceType(let serviceType):
            return "Invalid Multipeer Connectivity service type: \(serviceType)"
        }
    }
}

extension TransportServer: MCNearbyServiceAdvertiserDelegate {
    nonisolated public func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        Task { @MainActor [weak self] in
            guard let self else {
                invitationHandler(false, nil)
                return
            }
            self.handleInvitation(from: peerID, context: context, invitationHandler: invitationHandler)
        }
    }

    nonisolated public func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didNotStartAdvertisingPeer error: Error
    ) {
        Task { @MainActor [weak self] in
            self?.error = error
            self?.isRunning = false
        }
    }
}

extension TransportServer: MCSessionDelegate {
    nonisolated public func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor [weak self] in
            switch state {
            case .connected:
                self?.handleConnected(peerID: peerID)
            case .notConnected:
                self?.handleDisconnected(peerID: peerID)
            case .connecting:
                break
            @unknown default:
                break
            }
        }
    }

    nonisolated public func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { @MainActor [weak self] in
            await self?.handleMessage(data, from: peerID)
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
#endif
