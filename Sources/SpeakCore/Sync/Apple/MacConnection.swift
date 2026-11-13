import Combine
import Foundation
import Network

/// Where a Send to Mac client keeps the device credential each Mac issued it.
///
/// A shipping client must persist these in the Keychain: losing one only means
/// pairing with the code again, but storing it in plain preferences would let
/// anyone who reads them impersonate the phone.
public protocol TransportCredentialStore: AnyObject, Sendable {
    func credential(forMac macName: String) -> TransportDeviceCredential?
    func save(_ credential: TransportDeviceCredential, forMac macName: String)
    func removeCredential(forMac macName: String)
}

/// Keeps credentials for the lifetime of the store only. `MacConnection`'s default.
public final class InMemoryTransportCredentialStore: TransportCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var credentials: [String: TransportDeviceCredential] = [:]

    public init() {}

    public func credential(forMac macName: String) -> TransportDeviceCredential? {
        self.lock.withLock { self.credentials[macName] }
    }

    public func save(_ credential: TransportDeviceCredential, forMac macName: String) {
        self.lock.withLock { self.credentials[macName] = credential }
    }

    public func removeCredential(forMac macName: String) {
        self.lock.withLock { _ = self.credentials.removeValue(forKey: macName) }
    }
}

/// Client half of the local transport: connects to a Mac that runs
/// `TransportServer`, agrees encryption keys from the pairing code (or, after
/// the first pairing, from the device credential the Mac issued),
/// authenticates, then streams transcripts to it.
///
/// It lives in `SpeakCore` rather than the iOS library so that the shipping
/// client and the shipping server can be exercised against each other in one
/// test process.
///
/// There is no shipping caller. The iOS "Send to Mac" screen that used to drive
/// it was removed because nothing ever called `sendTranscript` — pairing worked
/// and no transcript was ever delivered. This type is retained deliberately as
/// the client that `TransportLoopbackTests` drives against the real server, so
/// the receiver keeps its wire-protocol coverage. The `speak` CLI and MCP instead
/// use `UnixSocketAutomationClient` with the separate local `AutomationServer`.
/// Do not delete this client without replacing the receiver's loopback coverage.
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

    private var channel: TransportChannel?
    private var receiveTask: Task<Void, Never>?
    private var sessionToken: String?
    private var sequenceNumber = 0

    /// Protocol version this client announces in its hello.
    ///
    /// Production always announces the version it was built with. Tests lower it
    /// to prove that the server's rejection path runs.
    private let announcedProtocolVersion: Int
    private let credentialStore: TransportCredentialStore

    public convenience init() {
        self.init(credentialStore: InMemoryTransportCredentialStore())
    }

    public convenience init(credentialStore: TransportCredentialStore) {
        self.init(announcedProtocolVersion: SpeakTransportProtocolVersion, credentialStore: credentialStore)
    }

    init(
        announcedProtocolVersion: Int,
        credentialStore: TransportCredentialStore = InMemoryTransportCredentialStore()
    ) {
        self.announcedProtocolVersion = announcedProtocolVersion
        self.credentialStore = credentialStore
    }

    /// Connects to a Mac found by discovery and authenticates.
    ///
    /// The first time, `pairingCode` proves the pairing and the Mac issues a
    /// device credential, which is stored under `name`. From then on the
    /// credential is used and `pairingCode` is ignored: the phone never falls
    /// back to the code on its own, because a spoofed Mac could otherwise ask
    /// for it and guess it offline (#1643). If the Mac has revoked the
    /// credential, call `forgetMac(named:)` before pairing with the code again.
    ///
    /// The state property carries the outcome: `.connected` on success, or
    /// `.error` with the reason the Mac gave, such as a protocol-version
    /// rejection or a wrong pairing code.
    public func connect(to endpoint: NWEndpoint, named name: String, pairingCode: String) async {
        self.tearDown()
        self.state = .connecting

        let channel = TransportChannel.connecting(to: endpoint)
        self.channel = channel
        let stored = self.credentialStore.credential(forMac: name)

        do {
            try await channel.start()
            self.state = .authenticating
            let secret: TransportPairingSecret = stored.map { .credential($0) } ?? .code(pairingCode)
            let issued = try await channel.establishSecureSession(
                secret: secret,
                requestsCredential: true,
                protocolVersion: self.announcedProtocolVersion
            )
            if let issued {
                self.credentialStore.save(issued, forMac: name)
            }
            try await self.authenticate(on: channel, pairingCode: stored == nil ? pairingCode : "")
        } catch {
            self.fail(with: error.localizedDescription)
            return
        }

        guard self.state == .connected else { return }
        self.connectedMacName = name
        self.startReceiveLoop(on: channel)
    }

    /// Deletes the credential for `name`, so the next `connect` pairs with the code.
    public func forgetMac(named name: String) {
        self.credentialStore.removeCredential(forMac: name)
    }

    /// Closes the connection and returns to the disconnected state.
    public func disconnect() {
        self.tearDown()
        self.state = .disconnected
    }

    /// Tells the Mac that a transcription session started.
    public func sendSessionStart(sessionId: String, model: String) async throws {
        guard let channel = self.connectedChannel() else { return }
        self.sequenceNumber = 0
        try await channel.send(.sessionStart(SessionStartMessage(sessionId: sessionId, model: model)))
    }

    /// Sends one transcript chunk to the Mac.
    public func sendTranscript(sessionId: String, text: String, isFinal: Bool) async throws {
        guard let channel = self.connectedChannel() else { return }
        self.sequenceNumber += 1
        let chunk = TranscriptChunkMessage(
            sessionId: sessionId,
            sequenceNumber: self.sequenceNumber,
            text: text,
            isFinal: isFinal
        )
        try await channel.send(.transcriptChunk(chunk))
    }

    /// Tells the Mac that a transcription session ended.
    public func sendSessionEnd(
        sessionId: String,
        finalText: String,
        duration: TimeInterval,
        wordCount: Int
    ) async throws {
        guard let channel = self.connectedChannel() else { return }
        let end = SessionEndMessage(
            sessionId: sessionId,
            finalText: finalText,
            duration: duration,
            wordCount: wordCount
        )
        try await channel.send(.sessionEnd(end))
    }

    // MARK: - Private

    private func connectedChannel() -> TransportChannel? {
        guard self.state == .connected else { return nil }
        return self.channel
    }

    private func authenticate(on channel: TransportChannel, pairingCode: String) async throws {
        let hello = HelloMessage(
            protocolVersion: self.announcedProtocolVersion,
            deviceName: DeviceIdentity.deviceName,
            deviceId: DeviceIdentity.deviceId
        )
        try await channel.send(.hello(hello))
        try await channel.send(.authenticate(AuthenticateMessage(pairingCode: pairingCode)))

        switch try await channel.receive() {
        case .authResult(let result) where result.success:
            guard ReleaseTrain.current.acceptsPeer(result.releaseTrain) else {
                self.fail(with: "Connect to a Mac running the same release train")
                return
            }
            guard let token = result.sessionToken else {
                self.fail(with: "The Mac accepted the pairing code without issuing a session token")
                return
            }
            self.sessionToken = token
            // The Mac raises its own ceiling at the same point, so both ends
            // agree on how large a transcript frame may be.
            await channel.admitSessionFrames()
            self.state = .connected
        case .authResult(let result):
            self.fail(with: result.errorMessage ?? "Authentication failed")
        case .error(let error):
            self.fail(with: error.message)
        default:
            self.fail(with: "The Mac sent an unexpected response")
        }
    }

    private func startReceiveLoop(on channel: TransportChannel) {
        self.receiveTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await channel.receive()
                    guard let self else { return }
                    self.handle(message, on: channel)
                } catch {
                    self?.handleReceiveFailure(error)
                    return
                }
            }
        }
    }

    private func handle(_ message: TransportMessage, on channel: TransportChannel) {
        switch message {
        case .ping:
            Task { try? await channel.send(.pong) }
        case .error(let error):
            self.fail(with: error.message)
        default:
            break
        }
    }

    private func handleReceiveFailure(_ error: Error) {
        guard self.state == .connected else { return }
        self.fail(with: error.localizedDescription)
    }

    /// Reports a failure and releases the connection, keeping the reason visible.
    ///
    /// `disconnect()` must not be used here: it resets the state to
    /// `.disconnected` and would hide the very message the user needs, such as
    /// "update the app" after a protocol-version rejection.
    private func fail(with message: String) {
        self.tearDown()
        self.state = .error(message)
    }

    private func tearDown() {
        self.receiveTask?.cancel()
        self.receiveTask = nil
        self.channel?.close()
        self.channel = nil
        self.sessionToken = nil
        self.connectedMacName = nil
        self.sequenceNumber = 0
    }
}
