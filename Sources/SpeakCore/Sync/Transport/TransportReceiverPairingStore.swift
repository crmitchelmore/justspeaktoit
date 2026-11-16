import Foundation

// MARK: - Receiver pairing state
//
// The portable counterpart of `PairingManager` for receivers that do not keep
// their state in `UserDefaults` (Windows and Linux). It applies the same rules:
// one six-digit code from the CSPRNG compared in constant time, the shared
// `PairingAttemptLimiter`, at most 32 device credentials, credentials revoked
// with their device, and a new code clearing every device and credential.

package struct TransportReceiverPairedDevice: Codable, Equatable, Sendable {
    package var id: String
    package var name: String
    package var pairedAt: Date

    package init(id: String, name: String, pairedAt: Date) {
        self.id = id
        self.name = name
        self.pairedAt = pairedAt
    }
}

/// Everything a receiver persists. Holds credential secrets: store it privately.
package struct TransportReceiverPairingState: Codable, Equatable, Sendable {
    package struct StoredCredential: Codable, Equatable, Sendable {
        package var credential: TransportDeviceCredential
        package var deviceID: String?
    }

    package var pairingCode: String?
    package var devices: [TransportReceiverPairedDevice] = []
    package var credentials: [StoredCredential] = []

    package init() {}
}

/// Thread-safe pairing state shared by every connection of one receiver.
package final class TransportReceiverPairingStore: @unchecked Sendable {
    static let maximumCredentials = 32

    private let lock = NSLock()
    private var state: TransportReceiverPairingState
    private var limiter = PairingAttemptLimiter()
    private let persist: @Sendable (TransportReceiverPairingState) -> Void
    private var changeHandler: (@Sendable () -> Void)?

    /// `persist` runs under the store's lock after every change.
    package init(
        state: TransportReceiverPairingState = .init(),
        persist: @escaping @Sendable (TransportReceiverPairingState) -> Void = { _ in }
    ) {
        self.state = state
        self.persist = persist
    }

    /// Called after a change that the Settings card shows (code or devices).
    package func setChangeHandler(_ handler: (@Sendable () -> Void)?) {
        lock.withLock { changeHandler = handler }
    }

    /// The current code without creating one, for a receiver that is off.
    package var storedPairingCode: String? {
        lock.withLock { state.pairingCode }
    }

    package var pairingCode: String {
        let (code, changed) = lock.withLock { () -> (String, Bool) in
            if let code = state.pairingCode { return (code, false) }
            let code = TransportPairingCode.generate()
            state.pairingCode = code
            persist(state)
            return (code, true)
        }
        if changed { notify() }
        return code
    }

    package var pairedDevices: [TransportReceiverPairedDevice] {
        lock.withLock { state.devices }
    }

    package var snapshot: TransportReceiverPairingState {
        lock.withLock { state }
    }

    /// A new code that forgets every paired device and credential.
    @discardableResult
    package func regeneratePairingCode() -> String {
        let code = lock.withLock { () -> String in
            let code = TransportPairingCode.generate()
            state = TransportReceiverPairingState()
            state.pairingCode = code
            limiter.recordSuccess()
            persist(state)
            return code
        }
        notify()
        return code
    }

    /// Compares a code in constant time without counting the attempt.
    package func validatePairingCode(_ code: String) -> Bool {
        let current = pairingCode
        return TransportPairingCode.constantTimeEquals(code, current)
    }

    /// Authorizes the encrypted handshake exactly as `PairingManager.authorize(_:)`.
    ///
    /// A named credential is checked against that credential alone and never
    /// touches the attempt limit. A code proof goes through the limit and, when
    /// the phone asked, is issued a credential in the same transaction.
    package func authorize(
        credentialID: UUID?, requestsCredential: Bool, now: Date,
        verifyCode: (String) -> Bool, verifyCredential: (TransportDeviceCredential) -> Bool
    ) -> (result: PairingAttemptResult, issued: TransportDeviceCredential?) {
        // Generates the first code outside the transaction so it is persisted once.
        _ = pairingCode
        return lock.withLock {
            if let credentialID {
                guard let stored = state.credentials.first(where: { $0.credential.id == credentialID }),
                      verifyCredential(stored.credential) else { return (.rejected, nil) }
                return (.accepted, nil)
            }
            if let remaining = limiter.lockoutRemaining(at: now) { return (.lockedOut(retryAfter: remaining), nil) }
            guard let code = state.pairingCode, verifyCode(code) else {
                limiter.recordFailure(at: now)
                return (.rejected, nil)
            }
            limiter.recordSuccess()
            guard requestsCredential else { return (.accepted, nil) }
            let credential = TransportDeviceCredential.generate()
            state.credentials.append(.init(credential: credential, deviceID: nil))
            state.credentials = Array(state.credentials.suffix(Self.maximumCredentials))
            persist(state)
            return (.accepted, credential)
        }
    }

    /// Records the device that authenticated and binds its credential to it.
    package func addPairedDevice(id: String, name: String, credentialID: UUID?, now: Date = Date()) {
        lock.withLock {
            if let index = state.devices.firstIndex(where: { $0.id == id }) {
                state.devices[index].name = name
            } else {
                state.devices.append(.init(id: id, name: name, pairedAt: now))
            }
            if let credentialID, let index = state.credentials.firstIndex(where: { $0.credential.id == credentialID }) {
                state.credentials[index].deviceID = id
            }
            persist(state)
        }
        notify()
    }

    /// Forgets a device and revokes every credential bound to it.
    package func removePairedDevice(id: String) {
        lock.withLock {
            state.devices.removeAll { $0.id == id }
            state.credentials.removeAll { $0.deviceID == id }
            persist(state)
        }
        notify()
    }

    package func hasCredential(_ credentialID: UUID) -> Bool {
        lock.withLock { state.credentials.contains { $0.credential.id == credentialID } }
    }

    private func notify() {
        let handler = lock.withLock { changeHandler }
        handler?()
    }
}
