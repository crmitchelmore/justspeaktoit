import Foundation

// MARK: - Session

/// The credentials returned by a successful sign-in.
///
/// The access token is short-lived and the refresh token rotates on every use,
/// so a copy captured from disk stops working as soon as the real device
/// refreshes.
public struct PaidAccessSession: Codable, Hashable, Sendable {
    public let accessToken: String
    public let accessTokenExpiresAt: Date
    public let refreshToken: String
    public let refreshTokenExpiresAt: Date
    public let userID: String

    public init(
        accessToken: String,
        accessTokenExpiresAt: Date,
        refreshToken: String,
        refreshTokenExpiresAt: Date,
        userID: String
    ) {
        self.accessToken = accessToken
        self.accessTokenExpiresAt = accessTokenExpiresAt
        self.refreshToken = refreshToken
        self.refreshTokenExpiresAt = refreshTokenExpiresAt
        self.userID = userID
    }

    /// Whether the access token should be refreshed before the next request.
    /// A margin avoids sending a token that expires mid-flight.
    public func needsRefresh(asOf now: Date = Date(), margin: TimeInterval = 60) -> Bool {
        self.accessTokenExpiresAt.timeIntervalSince(now) <= margin
    }

    public func isRefreshable(asOf now: Date = Date()) -> Bool {
        self.refreshTokenExpiresAt > now
    }
}

/// Persists the paid-access session.
///
/// Deliberately narrow: the session is a credential, so it goes in the same
/// Keychain vault as API keys rather than into user defaults.
public protocol PaidAccessSessionStoring: Sendable {
    func loadSession() async -> PaidAccessSession?
    func saveSession(_ session: PaidAccessSession) async throws
    func clearSession() async
}

/// Keychain-backed session storage.
public struct KeychainPaidAccessSessionStore: PaidAccessSessionStoring {
    public static let identifier = "paidaccess.session"

    private let storage: SecureStorage

    public init(storage: SecureStorage) {
        self.storage = storage
    }

    public func loadSession() async -> PaidAccessSession? {
        guard let raw = try? await storage.secret(identifier: Self.identifier),
              let data = raw.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder.paidAccess.decode(PaidAccessSession.self, from: data)
    }

    public func saveSession(_ session: PaidAccessSession) async throws {
        let data = try JSONEncoder.paidAccess.encode(session)
        guard let raw = String(data: data, encoding: .utf8) else {
            throw PaidAccessError.invalidResponse
        }
        try await self.storage.storeSecret(raw, identifier: Self.identifier)
    }

    public func clearSession() async {
        try? await self.storage.removeSecret(identifier: Self.identifier)
    }
}

// MARK: - Client protocol

/// The paid-access service, as the apps see it.
///
/// Everything the apps need is here, and nothing else is: there is no way to
/// name a model, assert an entitlement or report a cost, because those are all
/// server decisions.
public protocol PaidAccessClienting: Sendable {
    /// Exchanges a verified Sign in with Apple identity token for a session.
    func signInWithApple(
        identityToken: String,
        rawNonce: String,
        deviceLabel: String?
    ) async throws -> PaidAccessSession

    func refresh(session: PaidAccessSession) async throws -> PaidAccessSession
    func signOut(session: PaidAccessSession) async

    func entitlement(session: PaidAccessSession) async throws -> PaidEntitlement
    func routingPolicy(session: PaidAccessSession) async throws -> PaidRoutingPolicy

    /// Creates a Stripe Checkout session. Direct-download macOS only.
    func createCheckoutURL(session: PaidAccessSession) async throws -> URL
    /// Creates a Stripe customer-portal session. Direct-download macOS only.
    func createBillingPortalURL(session: PaidAccessSession) async throws -> URL

    /// Uploads a StoreKit signed transaction so the server can verify it and
    /// update the entitlement. App Store builds only.
    func syncStoreKitTransaction(
        session: PaidAccessSession,
        signedTransaction: String,
        signedRenewalInfo: String?
    ) async throws -> PaidEntitlement

    func transcribe(
        session: PaidAccessSession,
        audio: Data,
        contentType: String,
        language: String?,
        idempotencyKey: String
    ) async throws -> String

    func postProcess(
        session: PaidAccessSession,
        text: String,
        systemPrompt: String?,
        temperature: Double,
        idempotencyKey: String
    ) async throws -> String

    /// The URL an audio client should open for a proxied live session, with the
    /// session's bearer token attached. Vendor credentials never appear here.
    func liveTranscriptionRequest(
        session: PaidAccessSession,
        language: String?,
        sampleRate: Int
    ) throws -> URLRequest
}

// MARK: - Coding helpers

extension JSONDecoder {
    static let paidAccess: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}

extension JSONEncoder {
    static let paidAccess: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()
}
