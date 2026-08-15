import Combine
import Foundation
import Network

/// Client half of "Send to Mac": connects a device to a Mac that runs the
/// transport server, authenticates with the pairing code, then streams
/// transcripts to it.
///
/// It lives in `SpeakCore` rather than the iOS library so that the shipping
/// client and the shipping server can be exercised against each other in one
/// test process. The phone drives it through `SendToMacView`.
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

    public convenience init() {
        self.init(announcedProtocolVersion: SpeakTransportProtocolVersion)
    }

    init(announcedProtocolVersion: Int) {
        self.announcedProtocolVersion = announcedProtocolVersion
    }

    /// Connects to a Mac found by discovery and authenticates with `pairingCode`.
    ///
    /// The state property carries the outcome: `.connected` on success, or
    /// `.error` with the reason the Mac gave, such as a protocol-version
    /// rejection or a wrong pairing code.
    public func connect(to endpoint: NWEndpoint, named name: String, pairingCode: String) async {
        self.tearDown()
        self.state = .connecting

        let channel = TransportChannel.connecting(to: endpoint)
        self.channel = channel

        do {
            try await channel.start()
            self.state = .authenticating
            try await self.authenticate(on: channel, pairingCode: pairingCode)
        } catch {
            self.fail(with: error.localizedDescription)
            return
        }

        guard self.state == .connected else { return }
        self.connectedMacName = name
        self.startReceiveLoop(on: channel)
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
