import Combine
import Foundation
import Network

/// Sends finished transcripts from a phone or tablet to the paired Mac's
/// Send to Mac receiver.
///
/// Pairing presents the six-digit code once; the Mac issues a device
/// credential, which the store keeps. Every send opens a fresh connection with
/// that credential, delivers one transcript, waits for the Mac to acknowledge
/// it and disconnects. The sender never holds the pairing code, so a rejected
/// credential surfaces as an error and is never retried with the code: only the
/// user pairing again can present it (#1643).
@MainActor
public final class SendToMacSender: ObservableObject {
    public enum Activity: Equatable, Sendable {
        case idle
        case pairing(macName: String)
        case pairingFailed(String)
        case sending(macName: String)
        case sent(macName: String)
        case sendFailed(String)
    }

    @Published public private(set) var pairedMacName: String?
    @Published public private(set) var activity: Activity = .idle
    @Published public private(set) var isLoaded = false

    private let store: SendToMacPairingStore
    private let resolveEndpoint: (String) -> NWEndpoint
    private let connectTimeout: Duration
    private let acknowledgementTimeout: Duration

    public init(
        store: SendToMacPairingStore,
        resolveEndpoint: @escaping (String) -> NWEndpoint = SendToMacSender.bonjourEndpoint(named:),
        connectTimeout: Duration = .seconds(10),
        acknowledgementTimeout: Duration = .seconds(5)
    ) {
        self.store = store
        self.resolveEndpoint = resolveEndpoint
        self.connectTimeout = connectTimeout
        self.acknowledgementTimeout = acknowledgementTimeout
    }

    /// The Send to Mac service a Mac named `name` advertises over Bonjour.
    public nonisolated static func bonjourEndpoint(named name: String) -> NWEndpoint {
        .service(name: name, type: SpeakTransportServiceType, domain: "local.", interface: nil)
    }

    /// The pairing code with spaces removed, or nil unless it is six digits.
    public nonisolated static func normalizedPairingCode(_ code: String) -> String? {
        let digits = code.filter { !$0.isWhitespace }
        guard digits.count == 6, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return digits
    }

    public var isPaired: Bool {
        self.pairedMacName != nil
    }

    public var isBusy: Bool {
        switch self.activity {
        case .pairing, .sending: true
        default: false
        }
    }

    /// Reads the stored pairing. Safe to call more than once.
    public func load() async {
        guard !self.isLoaded else { return }
        await self.store.load()
        self.pairedMacName = self.store.pairedMacName
        self.isLoaded = true
    }

    /// Pairs with the Mac at `endpoint` using the code it shows.
    ///
    /// Pairing again is a deliberate choice, so any earlier pairing and any
    /// credential stored for `name` are dropped first.
    @discardableResult
    public func pair(with endpoint: NWEndpoint, named name: String, code: String) async -> Bool {
        guard !self.isBusy else { return false }
        guard let code = Self.normalizedPairingCode(code) else {
            self.activity = .pairingFailed("Enter the six-digit code shown on the Mac.")
            return false
        }
        self.activity = .pairing(macName: name)
        self.clearPairing()
        self.store.removeCredential(forMac: name)

        let connection = MacConnection(credentialStore: self.store)
        let failure = await self.connect(connection, to: endpoint, named: name, pairingCode: code)
        connection.disconnect()
        if let failure {
            self.store.removeCredential(forMac: name)
            self.activity = .pairingFailed(failure)
            return false
        }
        guard self.store.credential(forMac: name) != nil else {
            self.activity = .pairingFailed("Update Just Speak to It on the Mac, then pair again.")
            return false
        }
        self.store.setPairedMacName(name)
        self.pairedMacName = name
        self.activity = .idle
        return true
    }

    /// Sends one finished transcript to the paired Mac and waits for it to
    /// confirm receipt.
    @discardableResult
    public func send(_ text: String, model: String = "", duration: TimeInterval = 0) async -> Bool {
        guard !self.isBusy else { return false }
        guard let name = self.pairedMacName, self.store.credential(forMac: name) != nil else {
            self.activity = .sendFailed("Pair with a Mac in Settings first.")
            return false
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            self.activity = .sendFailed("There is no transcript to send.")
            return false
        }
        self.activity = .sending(macName: name)

        let connection = MacConnection(credentialStore: self.store)
        defer { connection.disconnect() }
        // The stored credential authenticates. No code is passed, so a Mac that
        // rejects the credential can never be answered with the pairing code.
        if let failure = await self.connect(connection, to: self.resolveEndpoint(name), named: name, pairingCode: "") {
            self.activity = .sendFailed(failure)
            return false
        }
        do {
            try await connection.deliverTranscript(
                text,
                model: model,
                duration: duration,
                acknowledgementTimeout: self.acknowledgementTimeout
            )
        } catch {
            self.activity = .sendFailed(error.localizedDescription)
            return false
        }
        self.activity = .sent(macName: name)
        return true
    }

    /// Forgets the paired Mac and deletes its credential.
    public func forget() {
        guard !self.isBusy else { return }
        self.clearPairing()
        self.activity = .idle
    }

    /// Clears a finished send or failure message.
    public func clearActivity() {
        guard !self.isBusy else { return }
        self.activity = .idle
    }

    // MARK: - Private

    private func clearPairing() {
        if let previous = self.store.pairedMacName {
            self.store.removeCredential(forMac: previous)
        }
        self.store.setPairedMacName(nil)
        self.pairedMacName = nil
    }

    /// Connects and authenticates, returning the reason on failure.
    ///
    /// A Bonjour endpoint for a Mac that is asleep or off the network never
    /// fails on its own, so the attempt is abandoned after `connectTimeout`.
    private func connect(
        _ connection: MacConnection,
        to endpoint: NWEndpoint,
        named name: String,
        pairingCode: String
    ) async -> String? {
        let timeout = self.connectTimeout
        let timer = Task { @MainActor () -> Bool in
            do { try await Task.sleep(for: timeout) } catch { return false }
            connection.disconnect()
            return true
        }
        await connection.connect(to: endpoint, named: name, pairingCode: pairingCode)
        timer.cancel()
        if await timer.value {
            return "Couldn't reach \(name). Check both devices are on the same network and Send to Mac is on."
        }
        switch connection.state {
        case .connected:
            return nil
        case .error(let message):
            return message
        default:
            return "Couldn't connect to \(name)."
        }
    }
}
