// Framework, storage and transport boundaries only. The Python test inserts
// actual initialisers, handlers, lifecycle, session and subscription filtering.
import Foundation

enum PaidAccessError: Error { case notSignedIn, invalidResponse, network(String)
    var errorDescription: String? { "Synthetic failure" }
}
public struct PaidEntitlement: Equatable, Sendable {
    let active: Bool
    static let unentitled = Self(active: false)
}
struct PaidRoutingPolicy: Equatable, Sendable {
    let known: Bool
    static let unknown = Self(known: false)
}
public struct EntitlementState: Sendable { let entitlement: PaidEntitlement; let policy: PaidRoutingPolicy }
public protocol PaidAccessClienting: Sendable {
    func refresh(session: PaidAccessSession) async throws -> PaidAccessSession
    func signOut(session: PaidAccessSession) async
    func entitlement(session: PaidAccessSession) async throws -> EntitlementState
    func syncStoreKitTransaction(session: PaidAccessSession, signedTransaction: String,
                                 signedRenewalInfo: String?) async throws -> PaidEntitlement
}
enum PaidBillingChannel { case storeKit, stripe }
struct AppSettings {}
enum PaidAccessHTTPClient { static let defaultBaseURL = URL(string: "https://unused.invalid")! }
// Prevent the extracted iOS initialiser from reading the host's preferences.
struct UserDefaults {
    static let standard = Self()
    func bool(forKey key: String) -> Bool { false }
}
enum PaidSubscriptionTerm { static let productIDs = Set(["subscription.monthly", "subscription.yearly"]) }
enum VerificationResult<Value: Sendable>: Sendable {
    case verified(Value), unverified(Value)
    var jwsRepresentation: String { "synthetic-signed-transaction" }
}
struct Transaction: Sendable {
    let productID: String
    @MainActor static var updates: AsyncStream<VerificationResult<Transaction>> {
        Probe.subscriptions += 1
        return AsyncStream { continuation in
            for update in Probe.updates { continuation.yield(update) }
            continuation.finish()
        }
    }
    @MainActor func finish() async { Probe.events.append("finish") }
}
@MainActor enum Probe {
    static var subscriptions = 0
    static var channel = PaidBillingChannel.storeKit
    static var updates: [VerificationResult<Transaction>] = []
    static var events: [String] = []
    static func reset() { subscriptions = 0; channel = .storeKit; updates = []; events = [] }
}
@MainActor final class Store: PaidAccessSessionStoring {
    var stored: PaidAccessSession?
    var reads = 0, saves = 0, clears = 0
    init(_ stored: PaidAccessSession?) { self.stored = stored }
    func loadSession() async -> PaidAccessSession? { reads += 1; return stored }
    func saveSession(_ session: PaidAccessSession) async throws { saves += 1; stored = session }
    func clearSession() async { clears += 1; stored = nil }
}
@MainActor final class Client: PaidAccessClienting {
    var calls = 0
    var failSync = false
    func refresh(session: PaidAccessSession) async throws -> PaidAccessSession {
        calls += 1; Probe.events.append("refresh"); return fresh
    }
    func signOut(session: PaidAccessSession) async { calls += 1; Probe.events.append("signOut") }
    func entitlement(session: PaidAccessSession) async throws -> EntitlementState {
        calls += 1; Probe.events.append("entitlement")
        return EntitlementState(entitlement: .init(active: true), policy: .init(known: true))
    }
    func syncStoreKitTransaction(session: PaidAccessSession, signedTransaction: String,
                                 signedRenewalInfo: String?) async throws -> PaidEntitlement {
        calls += 1; Probe.events.append("sync")
        if failSync { throw PaidAccessError.network("synthetic refusal") }
        return .init(active: true)
    }
}
func makeSession(_ token: String, expired: Bool = false) -> PaidAccessSession {
    PaidAccessSession(accessToken: token, accessTokenExpiresAt: Date().addingTimeInterval(expired ? -1 : 3600),
        refreshToken: "refresh-" + token, refreshTokenExpiresAt: Date().addingTimeInterval(7200), userID: token)
}
let old = makeSession("old", expired: true), fresh = makeSession("fresh")
@MainActor func require(_ condition: Bool, _ message: String) {
    if !condition { fatalError(message) }
}
// PRODUCTION inserted here.
@main struct Run {
    @MainActor static func main() async {
        let subscription = VerificationResult.verified(Transaction(productID: "subscription.monthly"))
        // Both initialisers are constructed with a seeded, refreshable session.
        // Disabled observation must not even subscribe, let alone rotate it.
        Probe.reset(); PaidAccessFeature.FEATURE_FLAG = false
        Probe.updates = [subscription]
        do {
            let store = Store(old), client = Client()
            let manager = MAKE_MANAGER
            require(manager.transactionListener == nil, "disabled listener was created")
            await manager.transactionListener?.value
            require(Probe.subscriptions == 0 && store.reads == 0 && store.saves == 0
                    && store.clears == 0 && client.calls == 0 && store.stored == old,
                    "disabled listener accessed paid state")
            // Direct handler admission is a separate guard, even without a listener.
            await manager.handleTransactionUpdate(subscription)
            require(store.reads == 0 && store.saves == 0 && store.clears == 0
                    && client.calls == 0 && Probe.events.isEmpty && store.stored == old,
                    "disabled handler accessed paid state")
        }
        // Enabled verified subscription: actual lifecycle rotates the expired
        // session, syncs first, finishes only after success, then refreshes state.
        Probe.reset(); PaidAccessFeature.FEATURE_FLAG = true
        Probe.updates = [subscription]
        do {
            let store = Store(old), client = Client()
            let manager = MAKE_MANAGER
            require(manager.transactionListener != nil, "enabled listener was not created")
            await manager.transactionListener?.value
            require(Probe.subscriptions == 1 && Probe.events == ["refresh", "sync", "finish", "entitlement"],
                    "enabled subscription order changed")
            require(store.stored == fresh && store.saves == 1 && store.clears == 0 && manager.entitlement.active,
                    "enabled session/entitlement success lost")
        }
        // Real core subscription filter rejects foreign and unverified results;
        // real handler never finishes a transaction rejected by server sync.
        for (result, fails, expected) in [
            (VerificationResult.verified(Transaction(productID: "other.product")), false, ["entitlement"]),
            (VerificationResult.unverified(Transaction(productID: "subscription.monthly")), false, ["entitlement"]),
            (subscription, true, ["sync", "entitlement"])
        ] {
            Probe.reset(); Probe.updates = [result]
            let store = Store(fresh), client = Client(); client.failSync = fails
            let manager = MAKE_MANAGER
            await manager.transactionListener?.value
            require(Probe.events == expected && !Probe.events.contains("finish"),
                    "unverified, foreign or rejected transaction was finished")
        }
        // macOS direct distribution never creates an automatic StoreKit listener.
        if IS_MAC {
            Probe.reset(); Probe.channel = .stripe; Probe.updates = [subscription]
            let store = Store(old), client = Client()
            let manager = MAKE_MANAGER
            require(manager.transactionListener == nil && store.reads == 0 && client.calls == 0,
                    "direct channel created a StoreKit listener")
        }
        print("automatic StoreKit controls passed")
    }
}
