// Controlled transport/storage boundaries; production lifecycle and manager
// methods are inserted by test_paid_access_session_boundaries.py.
import Foundation

enum PaidAccessError: Error { case notSignedIn, invalidResponse, network(String)
    var errorDescription: String? { "Synthetic failure" }
}
struct PaidEntitlement: Equatable, Sendable {
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
}
struct Transaction {}
struct VerificationResult<T> {}
enum PaidStoreKitSync {
    static func entitlement(for result: VerificationResult<Transaction>, session: PaidAccessSession,
                            client: any PaidAccessClienting) async throws -> PaidEntitlement? {
        try await client.entitlement(session: session).entitlement
    }
}
@MainActor final class Gate {
    var entered = false
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        entered = true
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() { opened = true; let pending = waiters; waiters = []; pending.forEach { $0.resume() } }
}
@MainActor final class Store: PaidAccessSessionStoring {
    var stored: PaidAccessSession?
    var saveGate: Gate?
    init(_ stored: PaidAccessSession?) { self.stored = stored }
    func loadSession() async -> PaidAccessSession? { stored }
    func saveSession(_ session: PaidAccessSession) async throws {
        await saveGate?.wait()
        stored = session
    }
    func clearSession() async { stored = nil }
}
@MainActor final class Client: PaidAccessClienting {
    let refreshGate = Gate()
    let entitlementGate = Gate()
    var revokeGate: Gate?
    var refreshCalls = 0
    var revoked: [String] = []
    var failEntitlement = false
    func refresh(session: PaidAccessSession) async throws -> PaidAccessSession {
        refreshCalls += 1
        await refreshGate.wait()
        return fresh
    }
    func signOut(session: PaidAccessSession) async {
        revoked.append(session.accessToken)
        await revokeGate?.wait()
    }
    func entitlement(session: PaidAccessSession) async throws -> EntitlementState {
        await entitlementGate.wait()
        if failEntitlement { throw PaidAccessError.notSignedIn }
        return EntitlementState(entitlement: .init(active: true), policy: .init(known: true))
    }
}
func makeSession(_ token: String, expired: Bool = false) -> PaidAccessSession {
    PaidAccessSession(accessToken: token, accessTokenExpiresAt: Date().addingTimeInterval(expired ? -1 : 3600),
        refreshToken: "refresh-" + token, refreshTokenExpiresAt: Date().addingTimeInterval(7200), userID: token)
}
let old = makeSession("old", expired: true)
let fresh = makeSession("fresh")
let replacement = makeSession("replacement")
@MainActor func until(_ condition: () -> Bool) async {
    for _ in 0..<10000 {
        if condition() { return }
        await Task.yield()
    }
    fatalError("Controlled operation did not reach its boundary")
}
@MainActor func require(_ condition: Bool, _ message: String) {
    if !condition { fatalError(message) }
}
// MANAGER inserted here.
@main struct Run {
    @MainActor static func main() async throws {
        // Success control: rotating refresh is shared, saved and usable.
        do {
            let store = Store(old), client = Client()
            let manager = Manager(client: client, store: store)
            let first = Task { await manager.currentSession() }
            await until { client.refreshGate.entered }
            let second = Task { await manager.currentSession() }
            for _ in 0..<30 { await Task.yield() }
            require(client.refreshCalls == 1, "refresh was not single flight")
            client.refreshGate.open()
            let a = await first.value, b = await second.value
            require(a == fresh && b == fresh && store.stored == fresh, "successful refresh lost")
            require(manager.isSignedIn, "successful refresh did not sign in")
        }
        // Empty-store restoration while sign-in awaits auth must not revoke its generation.
        do {
            let store = Store(nil), client = Client()
            let manager = Manager(client: client, store: store)
            let generation = manager.sessions.generation
            await manager.refreshEntitlement()
            require(generation == manager.sessions.generation, "empty restore invalidated sign-in")
            let accepted = try await manager.sessions.acceptSignIn(fresh, generation: generation)
            require(accepted != nil && accepted != generation && store.stored == fresh, "pending sign-in was silently discarded")
        }
        // Logout while the server is issuing a refreshed session.
        do {
            let store = Store(old), client = Client()
            let manager = Manager(client: client, store: store)
            let refreshing = Task { await manager.currentSession() }
            await until { client.refreshGate.entered }
            await manager.signOut()
            client.refreshGate.open()
            let result = await refreshing.value
            require(result == nil && store.stored == nil && !manager.isSignedIn, "refresh resurrected logout")
            await until { client.revoked.contains("fresh") }
        }
        // Logout while a previously admitted store write is suspended.
        do {
            let store = Store(old), client = Client()
            store.saveGate = Gate(); client.refreshGate.open()
            let manager = Manager(client: client, store: store)
            let refreshing = Task { await manager.currentSession() }
            await until { store.saveGate!.entered }
            let logout = Task { await manager.signOut() }
            await until { !manager.isSignedIn && manager.isBusy }
            store.saveGate!.open()
            await logout.value
            let result = await refreshing.value
            require(result == nil && store.stored == nil, "late storage write survived logout")
        }
        // A new login survives old refresh completion and its late revoke.
        do {
            let store = Store(old), client = Client()
            let manager = Manager(client: client, store: store)
            let refreshing = Task { await manager.currentSession() }
            await until { client.refreshGate.entered }
            await manager.signOut()
            let accepted = try await manager.sessions.saveSession(replacement, generation: manager.sessions.generation)
            require(accepted, "replacement login failed")
            manager.isSignedIn = true
            client.refreshGate.open()
            _ = await refreshing.value
            await until { client.revoked.contains("fresh") }
            require(store.stored == replacement && manager.isSignedIn, "old refresh damaged replacement")
            require(!client.revoked.contains("replacement"), "replacement was revoked")
        }
        // Both entitlement writers still accept current-account success.
        for storeKit in [false, true] {
            let store = Store(fresh), client = Client()
            client.entitlementGate.open()
            let manager = Manager(client: client, store: store)
            if storeKit {
                let accepted = await manager.syncIfSubscription(VerificationResult<Transaction>(),
                    session: fresh, generation: manager.sessions.generation)
                require(accepted, "current StoreKit result was discarded")
            } else { await manager.refreshEntitlement() }
            require(manager.entitlement.active, "current entitlement was discarded")
        }
        // Both entitlement writers ignore successful and failed stale replies.
        for storeKit in [false, true] { for failure in [false, true] {
            let store = Store(fresh), client = Client()
            client.failEntitlement = failure
            let manager = Manager(client: client, store: store)
            let generation = manager.sessions.generation
            let pending = Task {
                if storeKit {
                    _ = await manager.syncIfSubscription(VerificationResult<Transaction>(),
                        session: fresh, generation: generation)
                } else { await manager.refreshEntitlement() }
            }
            await until { client.entitlementGate.entered }
            await manager.signOut()
            client.entitlementGate.open()
            await pending.value
            require(manager.entitlement == .unentitled && manager.policy == .unknown,
                "stale entitlement restored paid state")
            require(manager.lastError == nil, "stale failure changed current error")
        }}
        // Empty-store refresh during slow remote logout must not stick busy state.
        do {
            let store = Store(fresh), client = Client()
            client.revokeGate = Gate()
            let manager = Manager(client: client, store: store)
            let logout = Task { await manager.signOut() }
            await until { client.revokeGate!.entered }
            await manager.refreshEntitlement()
            client.revokeGate!.open()
            await logout.value
            require(!manager.isBusy && store.stored == nil, "logout left busy state stuck")
        }
        // A remote revoke completing after a new account never clears that account.
        do {
            let store = Store(fresh), client = Client()
            client.revokeGate = Gate()
            let manager = Manager(client: client, store: store)
            let logout = Task { await manager.signOut() }
            await until { client.revokeGate!.entered }
            _ = await manager.sessions.clear().value
            _ = try await manager.sessions.saveSession(replacement, generation: manager.sessions.generation)
            manager.isSignedIn = true
            manager.busyOperation = UUID(); manager.isBusy = true
            client.revokeGate!.open()
            await logout.value
            require(store.stored == replacement && manager.isSignedIn && manager.isBusy,
                "old logout modified replacement account or operation")
        }
        print("13 controlled account lifecycle cases passed")
    }
}
