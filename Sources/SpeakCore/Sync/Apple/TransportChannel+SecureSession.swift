import Foundation

// MARK: - Encrypted handshake

/// The protocol v2 handshake each side runs after `start()` and before any
/// message. Lives in its own file only to keep `TransportChannel.swift` short.
extension TransportChannel {
    /// Mac side: the device credential this session used or issued, if any.
    public var credentialID: UUID? {
        self.sessionCredentialID
    }

    /// Mac side: whether the phone proved a device credential rather than the code.
    public var isAuthenticatedByCredential: Bool {
        self.sessionUsedCredential
    }

    /// Mac side: the refusal a phone gets when the credential it names is unknown
    /// or revoked. The phone does not fall back to the code on its own.
    public static let revokedCredentialMessage =
        "This device is no longer paired with this Mac. Pair again with the code shown on the Mac."

    /// Phone side: agrees session keys with the Mac using `pairingCode`.
    ///
    /// Returns once the Mac has proved it holds the same code. Throws
    /// `TransportRejection` with the Mac's reason when it refuses the code,
    /// is locked out or runs a different protocol version.
    public func establishSecureSession(pairingCode: String) async throws {
        _ = try await self.establishSecureSession(
            secret: .code(pairingCode),
            requestsCredential: false,
            protocolVersion: SpeakTransportProtocolVersion
        )
    }

    /// Phone side: agrees session keys with the Mac using `secret`.
    ///
    /// With the pairing code, the phone asks the Mac for a device credential and
    /// returns it when the Mac issues one; store it and pass it as `secret` from
    /// then on. With a credential, it returns nil. Throws `TransportRejection`
    /// with the Mac's reason when it refuses, including
    /// `revokedCredentialMessage` for a credential it no longer holds.
    public func establishSecureSession(secret: TransportPairingSecret) async throws -> TransportDeviceCredential? {
        try await self.establishSecureSession(
            secret: secret,
            requestsCredential: true,
            protocolVersion: SpeakTransportProtocolVersion
        )
    }

    func establishSecureSession(pairingCode: String, protocolVersion: Int) async throws {
        _ = try await self.establishSecureSession(
            secret: .code(pairingCode),
            requestsCredential: false,
            protocolVersion: protocolVersion
        )
    }

    func establishSecureSession(
        secret: TransportPairingSecret,
        requestsCredential: Bool,
        protocolVersion: Int
    ) async throws -> TransportDeviceCredential? {
        guard self.session == nil else { return nil }
        let handshake = try TransportClientHandshake(
            protocolVersion: protocolVersion,
            secret: secret,
            requestsCredential: requestsCredential
        )
        try await self.sendFrame(handshake.frame)

        let reply = try await self.receiveFrame()
        guard TransportKeyShare.decode(reply) != nil else {
            throw self.rejection(in: reply) ?? TransportSecurityError.malformedHandshake
        }
        let finish = try handshake.finish(serverFrame: reply)
        var keys = finish.keys
        try await self.sendFrame(finish.finished)

        let confirmation = try await self.receiveFrame()
        guard let opened = try? keys.inbound.open(confirmation) else {
            // The Mac could not open our frame, so it answered in plaintext.
            // Only a refusal is read from such a frame; never a success.
            throw self.rejection(in: confirmation) ?? TransportSecurityError.unauthenticatedFrame
        }
        let issued = try TransportKeySchedule.credential(inServerFinished: opened)
        // Only a code-based handshake that asked for one may receive a credential.
        if issued != nil, case .credential = secret { throw TransportSecurityError.unauthenticatedFrame }
        if issued != nil, !requestsCredential { throw TransportSecurityError.unauthenticatedFrame }
        self.session = keys
        return issued
    }

    /// Mac side: answers the phone's key share and checks its pairing proof.
    ///
    /// `authorize` receives the phone's proof and must run it through
    /// `PairingManager.authorize(_:)` (or the pairing attempt limit), which may
    /// also issue the phone a device credential. A plaintext or wrong-version
    /// peer, a wrong code, an unknown credential and a lockout are each refused
    /// with a plaintext reason and a thrown `TransportRejection`; nothing
    /// encrypted is sent until the code or credential is proved.
    public func acceptSecureSession(
        authorize: @Sendable (TransportPairingProof) -> PairingAttemptResult
    ) async throws {
        try await self.acceptSecureSession(protocolVersion: SpeakTransportProtocolVersion, authorize: authorize)
    }

    func acceptSecureSession(
        protocolVersion: Int,
        authorize: @Sendable (TransportPairingProof) -> PairingAttemptResult
    ) async throws {
        guard self.session == nil else { return }
        let handshake: TransportServerHandshake
        do {
            handshake = try TransportServerHandshake(
                clientFrame: try await self.receiveFrame(),
                protocolVersion: protocolVersion
            )
        } catch let refusal as TransportServerHandshake.Refusal {
            throw await self.refuse(refusal, serverVersion: protocolVersion)
        }
        try await self.sendFrame(handshake.frame)

        let proof = TransportPairingProof(
            schedule: handshake.schedule,
            clientFinished: try await self.receiveFrame(),
            credentialID: handshake.clientShare.credentialID,
            requestsCredential: handshake.clientShare.requestsCredential == true
        )
        let message: String
        switch authorize(proof) {
        case .accepted:
            guard var keys = proof.acceptedKeys else { throw TransportSecurityError.unauthenticatedFrame }
            let issued = proof.issuedCredential
            try await self.sendFrame(try keys.outbound.seal(TransportKeySchedule.serverFinished(issuing: issued)))
            self.session = keys
            self.sessionCredentialID = proof.credentialID ?? issued?.id
            self.sessionUsedCredential = proof.credentialID != nil
            return
        case .rejected where proof.credentialID != nil:
            message = Self.revokedCredentialMessage
        case .rejected:
            message = "Invalid pairing code"
        case .lockedOut(let retryAfter):
            let seconds = Int(retryAfter.rounded(.up))
            message = "Too many failed pairing attempts. Try again in \(seconds) seconds."
        }
        try? await self.sendPlaintext(.authResult(AuthResultMessage(success: false, errorMessage: message)))
        throw TransportRejection(message: message)
    }

    private func refuse(_ refusal: TransportServerHandshake.Refusal, serverVersion: Int) async -> Error {
        let reply: ErrorMessage
        switch refusal {
        case .plaintextHello(let version) where version == serverVersion:
            reply = ErrorMessage(code: 426, message: "Send to Mac requires an encrypted connection")
        case .plaintextHello(let version), .versionMismatch(let version):
            reply = .protocolMismatch(clientVersion: version, serverVersion: serverVersion)
        case .malformed:
            return TransportSecurityError.malformedHandshake
        }
        try? await self.sendPlaintext(.error(reply))
        return TransportRejection(message: reply.message)
    }

    /// A plaintext refusal the peer sent instead of a handshake frame.
    private func rejection(in frame: Data) -> TransportRejection? {
        switch try? self.decoder.decode(TransportMessage.self, from: frame) {
        case .authResult(let result)? where !result.success:
            TransportRejection(message: result.errorMessage ?? "Authentication failed")
        case .error(let error)?:
            TransportRejection(message: error.message)
        default:
            nil
        }
    }
}
