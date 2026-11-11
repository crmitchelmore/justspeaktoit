import CryptoKit
import Foundation
import Security
import StoreKit

/// The paid-access state an app manager publishes.
public struct PaidAccessFlowState: Equatable {
    public var entitlement: PaidEntitlement = .unentitled
    public var policy: PaidRoutingPolicy = .unknown
    public var isSignedIn = false
    public var isBusy = false
    public var lastError: String?
    /// Subscription products the App Store returned, cheapest first.
    public var products: [Product] = []

    public init() {}
}

/// The paid-access session, entitlement, sign-in and StoreKit purchase flow
/// shared by the macOS `PaidAccessManager` and the iOS `PaidAccessStore`.
///
/// The app never decides whether it is entitled: it presents evidence (an
/// Apple identity token, a StoreKit signed transaction) and reads back the
/// server's verdict. Every step is fenced by the session generation, so work
/// admitted for an account the user has since left never touches state.
///
/// Platforms keep what genuinely differs: presenting Sign in with Apple,
/// opening URLs, choosing the billing channel and deciding when StoreKit
/// observation runs. They publish `state` through `onChange`.
@MainActor
public final class PaidAccessFlow {
    public private(set) var state = PaidAccessFlowState() {
        didSet {
            guard state != oldValue else { return }
            onChange?(state)
        }
    }
    /// Called after every change to `state`.
    public var onChange: ((PaidAccessFlowState) -> Void)?
    public let sessions: PaidAccessSessionLifecycle
    private let client: any PaidAccessClienting
    private var busyOperation = UUID()

    public init(client: any PaidAccessClienting, sessionStore: any PaidAccessSessionStoring) {
        self.client = client
        self.sessions = PaidAccessSessionLifecycle(client: client, store: sessionStore)
    }

    public var generation: UUID { sessions.generation }

    // MARK: - Operations

    /// Marks the flow busy until `endOperation` is called with the returned
    /// identifier, unless a newer operation has begun meanwhile.
    public func beginOperation(clearingError: Bool) -> UUID {
        let operation = UUID()
        busyOperation = operation
        state.isBusy = true
        if clearingError { state.lastError = nil }
        return operation
    }

    public func endOperation(_ operation: UUID) {
        if operation == busyOperation { state.isBusy = false }
    }

    public func report(_ message: String?) {
        state.lastError = message
    }

    /// Runs `body` as a busy operation for the signed-in account, reporting
    /// "not signed in" when there is no session.
    public func withSignedInOperation(
        clearingError: Bool,
        _ body: (PaidAccessSession, UUID) async -> Void
    ) async {
        let operation = beginOperation(clearingError: clearingError)
        defer { endOperation(operation) }
        let generation = generation
        guard let session = await currentSession() else {
            state.lastError = PaidAccessError.notSignedIn.errorDescription
            return
        }
        await body(session, generation)
    }

    // MARK: - Session

    /// A usable session, rotating the refresh token when the access token is
    /// close to expiry, or nil when the user is not signed in.
    public func currentSession() async -> PaidAccessSession? {
        let generation = sessions.generation
        do {
            let session = try await sessions.currentSession()
            guard generation == sessions.generation else { return nil }
            state.isSignedIn = session != nil
            if session == nil {
                // An empty store is not another logout: sign-in may be awaiting Apple.
                state.entitlement = .unentitled
                state.policy = .unknown
            }
            return session
        } catch {
            guard generation == sessions.generation else { return nil }
            await clearSession()
            return nil
        }
    }

    private func clearSession() async {
        let clearing = sessions.clear()
        state.isSignedIn = false
        state.entitlement = .unentitled
        state.policy = .unknown
        _ = await clearing.value
    }

    // MARK: - Entitlement

    public func refreshEntitlement() async {
        let generation = sessions.generation
        guard let session = await currentSession() else {
            guard generation == sessions.generation else { return }
            state.entitlement = .unentitled
            state.policy = .unknown
            return
        }

        do {
            // One call, one commit. Fetching the policy separately could leave an
            // active entitlement paired with an empty policy — entitled, with
            // nowhere to send the request — if the second call failed.
            let entitlementState = try await client.entitlement(session: session)
            guard generation == sessions.generation else { return }
            state.entitlement = entitlementState.entitlement
            state.policy = entitlementState.policy
            state.lastError = nil
        } catch PaidAccessError.notSignedIn {
            guard generation == sessions.generation else { return }
            await clearSession()
        } catch {
            guard generation == sessions.generation else { return }
            // Keep the last known entitlement so a brief outage does not flip the UI
            // to "not subscribed"; routing still re-checks expiry locally.
            state.lastError = (error as? PaidAccessError)?.errorDescription
        }
    }

    // MARK: - Sign in and out

    /// Signs in with Apple. `identityToken` presents the platform's Apple
    /// sign-in for a hashed nonce; `errorMessage` says what to show for a
    /// failure, nil when the user simply dismissed it.
    public func signIn(
        deviceLabel: String?,
        identityToken: (_ hashedNonce: String) async throws -> String,
        errorMessage: (Error) -> String?
    ) async {
        guard !state.isBusy else { return }
        let clearing = sessions.clear()
        let generation = sessions.generation
        state.isSignedIn = false
        state.entitlement = .unentitled
        state.policy = .unknown
        let operation = beginOperation(clearingError: true)
        defer { endOperation(operation) }

        _ = await clearing.value
        guard generation == sessions.generation else { return }

        let rawNonce = PaidAccessNonce.makeRaw()
        do {
            // Apple echoes the hashed nonce back in the identity token; the server is
            // given the raw nonce and re-derives the digest, which is what binds the
            // token to this specific request.
            let token = try await identityToken(PaidAccessNonce.sha256Hex(rawNonce))
            guard generation == sessions.generation else { return }

            let session = try await client.signInWithApple(
                identityToken: token,
                rawNonce: rawNonce,
                deviceLabel: deviceLabel
            )
            guard let signedInGeneration = try await sessions.acceptSignIn(session, generation: generation),
                signedInGeneration == sessions.generation
            else { return }
            state.isSignedIn = true
            await refreshEntitlement()
        } catch {
            guard generation == sessions.generation else { return }
            state.lastError = errorMessage(error)
        }
    }

    public func signOut() async {
        let clearing = sessions.clear()
        state.isSignedIn = false
        state.entitlement = .unentitled
        state.policy = .unknown
        let operation = beginOperation(clearingError: false)
        defer { endOperation(operation) }

        // Clear local credentials first. A slow revocation must never clear a
        // replacement account or restore state from an earlier refresh.
        if let session = await clearing.value {
            await client.signOut(session: session)
        }
    }

    // MARK: - StoreKit

    public func loadProducts() async {
        let loaded = try? await Product.products(for: PaidSubscriptionTerm.productIDs)
        state.products = (loaded ?? []).sorted { $0.price < $1.price }
    }

    /// The loaded StoreKit product for a term, if the App Store returned it.
    public func product(for term: PaidSubscriptionTerm) -> Product? {
        state.products.first { $0.id == term.productID }
    }

    /// Buys `term` through StoreKit for the signed-in account, then syncs the
    /// signed transaction and refreshes the entitlement.
    public func purchaseThroughStoreKit(
        term: PaidSubscriptionTerm,
        session: PaidAccessSession,
        generation: UUID
    ) async {
        guard generation == sessions.generation else { return }
        if state.products.isEmpty {
            await loadProducts()
        }
        guard generation == sessions.generation else { return }
        // Matched by product id, never by position: `products.first` bought the
        // cheapest loaded product whatever the user had chosen.
        guard let product = product(for: term) else {
            state.lastError = "The \(term.displayName.lowercased()) subscription is not available in this build yet."
            return
        }

        // Bind the purchase to this account before it happens. The server rejects a
        // signed transaction whose `appAccountToken` is not the caller's, so a
        // purchase made without one produces a receipt nobody can redeem.
        guard let accountToken = session.storeKitAccountToken else {
            state.lastError = """
                This account cannot be linked to an App Store purchase. \
                Sign out, sign back in and try again.
                """
            return
        }

        do {
            let result = try await product.purchase(options: [.appAccountToken(accountToken)])
            guard generation == sessions.generation else { return }
            await handlePurchaseResult(result, session: session, generation: generation)
        } catch {
            guard generation == sessions.generation else { return }
            state.lastError = "The purchase could not be completed."
        }
    }

    /// Re-sends every current StoreKit entitlement for verification, then
    /// refreshes the server's verdict.
    public func restoreStoreKitPurchases(session: PaidAccessSession, generation: UUID) async {
        for await result in Transaction.currentEntitlements {
            guard generation == sessions.generation else { return }
            await syncIfSubscription(result, session: session, generation: generation)
        }
        guard generation == sessions.generation else { return }
        await refreshEntitlement()
    }

    /// Renewals, refunds and family-sharing changes arrive without any user
    /// action, so the entitlement stays correct between launches.
    public func handleTransactionUpdate(_ result: VerificationResult<Transaction>) async {
        let generation = sessions.generation
        guard let session = await currentSession() else { return }
        if await syncIfSubscription(result, session: session, generation: generation),
            case .verified(let transaction) = result {
            await transaction.finish()
        }
        guard generation == sessions.generation else { return }
        await refreshEntitlement()
    }

    private func handlePurchaseResult(
        _ result: Product.PurchaseResult,
        session: PaidAccessSession,
        generation: UUID
    ) async {
        guard generation == sessions.generation else { return }
        switch result {
        case .success(let verification):
            if await syncIfSubscription(verification, session: session, generation: generation),
                case .verified(let transaction) = verification {
                await transaction.finish()
            }
            guard generation == sessions.generation else { return }
            await refreshEntitlement()
        case .pending:
            state.lastError = """
                The purchase is awaiting approval (for example Ask to Buy). \
                Access activates automatically once it is approved.
                """
        case .userCancelled:
            break
        @unknown default:
            break
        }
    }

    /// Sends a signed transaction to the server for verification.
    ///
    /// Only locally verified subscription transactions are forwarded, and the
    /// server verifies the signature again regardless — the device's verdict is
    /// never trusted on its own.
    @discardableResult
    private func syncIfSubscription(
        _ result: VerificationResult<Transaction>,
        session: PaidAccessSession,
        generation: UUID
    ) async -> Bool {
        guard generation == sessions.generation else { return false }
        do {
            guard
                let entitlement = try await PaidStoreKitSync.entitlement(
                    for: result, session: session, client: client
                )
            else { return false }
            guard generation == sessions.generation else { return false }
            state.entitlement = entitlement
            return true
        } catch {
            guard generation == sessions.generation else { return false }
            state.lastError =
                (error as? PaidAccessError)?.errorDescription
                ?? "Could not confirm the subscription."
            return false
        }
    }
}

/// The Sign in with Apple nonce. Apple replays its hash in the identity token,
/// so a captured token cannot be replayed against a different request.
public enum PaidAccessNonce {
    /// 32 bytes of entropy, URL-safe.
    public static func makeRaw() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = (0..<32).map { _ in UInt8.random(in: UInt8.min...UInt8.max) }
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
