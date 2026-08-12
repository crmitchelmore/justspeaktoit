#if os(iOS)
import AuthenticationServices
import CryptoKit
import Foundation
import SpeakCore
import StoreKit
import UIKit

/// Paid-access state for iOS.
///
/// iOS always ships through the App Store, so billing is always StoreKit; the
/// Stripe path exists only for the direct-download Mac build. Identity is
/// shared, so signing in here with the same Apple account picks up a
/// subscription bought on a Mac and vice versa.
///
/// Nothing here is required to dictate: on-device transcription and personal
/// API keys keep working with no account at all.
@MainActor
public final class PaidAccessStore: NSObject, ObservableObject {
    // swiftlint:disable:previous type_body_length

    public static let shared = PaidAccessStore()

    @Published public private(set) var entitlement: PaidEntitlement = .unentitled
    @Published public private(set) var policy: PaidRoutingPolicy = .unknown
    @Published public private(set) var isSignedIn = false
    @Published public private(set) var isBusy = false
    @Published public private(set) var lastError: String?
    @Published public private(set) var products: [Product] = []

    /// Mirrors the macOS setting: hides the model pickers and lets the
    /// subscription pick the best model for each task.
    @Published public var simpleModelChoices: Bool {
        didSet { UserDefaults.standard.set(simpleModelChoices, forKey: "simpleModelChoices") }
    }

    /// Off by default, and ignored without a verified entitlement.
    @Published public var paidRoutingEnabled: Bool {
        didSet { UserDefaults.standard.set(paidRoutingEnabled, forKey: "paidAccessRoutingEnabled") }
    }

    public static let subscriptionProductIDs = [
        "com.justspeaktoit.paid.monthly",
        "com.justspeaktoit.paid.yearly"
    ]

    private let client: any PaidAccessClienting
    private let sessionStore: any PaidAccessSessionStoring
    private var transactionListener: Task<Void, Never>?
    private var signInContinuation: CheckedContinuation<ASAuthorization, Error>?

    override private convenience init() {
        self.init(
            client: PaidAccessHTTPClient(),
            sessionStore: KeychainPaidAccessSessionStore(
                storage: AppSettings.canonicalCredentialStorage
            )
        )
    }

    init(client: any PaidAccessClienting, sessionStore: any PaidAccessSessionStoring) {
        self.client = client
        self.sessionStore = sessionStore
        self.simpleModelChoices = UserDefaults.standard.bool(forKey: "simpleModelChoices")
        self.paidRoutingEnabled = UserDefaults.standard.bool(forKey: "paidAccessRoutingEnabled")
        super.init()

        self.transactionListener = Task { [weak self] in
            for await update in Transaction.updates {
                guard let self else { return }
                await self.handleTransactionUpdate(update)
            }
        }
    }

    deinit {
        self.transactionListener?.cancel()
    }

    // MARK: - Derived state

    public var billingChannel: PaidBillingChannel {
        DistributionChannel.current.paidBillingChannel
    }

    public var simpleModelChoicesPolicy: SimpleModelChoicesPolicy {
        SimpleModelChoicesPolicy(
            isEnabled: self.simpleModelChoices,
            hasPaidRouting: self.entitlement.allowsPaidRouting()
        )
    }

    public var isPaidRoutingActive: Bool {
        self.paidRoutingEnabled && self.entitlement.allowsPaidRouting()
    }

    public var router: PaidAccessRouter {
        PaidAccessRouter(
            entitlement: self.entitlement,
            policy: self.policy,
            isPaidRoutingPreferred: self.paidRoutingEnabled
        )
    }

    // MARK: - Session

    private func currentSession() async -> PaidAccessSession? {
        guard let stored = await self.sessionStore.loadSession() else {
            self.isSignedIn = false
            return nil
        }
        self.isSignedIn = true

        guard stored.needsRefresh() else { return stored }
        guard stored.isRefreshable() else {
            await self.clearSession()
            return nil
        }

        do {
            let refreshed = try await self.client.refresh(session: stored)
            try await self.sessionStore.saveSession(refreshed)
            return refreshed
        } catch PaidAccessError.notSignedIn {
            await self.clearSession()
            return nil
        } catch {
            return stored
        }
    }

    private func clearSession() async {
        await self.sessionStore.clearSession()
        self.isSignedIn = false
        self.entitlement = .unentitled
        self.policy = .unknown
    }

    // MARK: - Entitlement

    public func refreshEntitlement() async {
        guard let session = await self.currentSession() else {
            self.entitlement = .unentitled
            self.policy = .unknown
            return
        }

        do {
            self.entitlement = try await self.client.entitlement(session: session)
            self.policy = try await self.client.routingPolicy(session: session)
            self.lastError = nil
        } catch PaidAccessError.notSignedIn {
            await self.clearSession()
        } catch {
            self.lastError = (error as? PaidAccessError)?.errorDescription
        }
    }

    // MARK: - Sign in with Apple

    public func signIn() async {
        self.isBusy = true
        self.lastError = nil
        defer { self.isBusy = false }

        let rawNonce = Self.makeRawNonce()
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = Self.sha256Hex(rawNonce)

        do {
            let authorization = try await self.performAuthorization(for: request)
            guard
                let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                let tokenData = credential.identityToken,
                let identityToken = String(data: tokenData, encoding: .utf8)
            else {
                self.lastError = "Apple did not return an identity token."
                return
            }

            let session = try await self.client.signInWithApple(
                identityToken: identityToken,
                rawNonce: rawNonce,
                deviceLabel: UIDevice.current.name
            )
            try await self.sessionStore.saveSession(session)
            self.isSignedIn = true
            await self.refreshEntitlement()
        } catch let error as ASAuthorizationError where error.code == .canceled {
            // The user dismissed the sheet.
        } catch {
            self.lastError = (error as? PaidAccessError)?.errorDescription
                ?? "Could not sign in with Apple."
        }
    }

    public func signOut() async {
        self.isBusy = true
        defer { self.isBusy = false }

        if let session = await self.sessionStore.loadSession() {
            await self.client.signOut(session: session)
        }
        await self.clearSession()
    }

    private func performAuthorization(
        for request: ASAuthorizationAppleIDRequest
    ) async throws -> ASAuthorization {
        try await withCheckedThrowingContinuation { continuation in
            self.signInContinuation = continuation
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }

    private func resumeSignIn(with result: Result<ASAuthorization, Error>) {
        guard let continuation = self.signInContinuation else { return }
        self.signInContinuation = nil
        continuation.resume(with: result)
    }

    // MARK: - Purchase

    public func loadProducts() async {
        let loaded = try? await Product.products(for: Self.subscriptionProductIDs)
        self.products = (loaded ?? []).sorted { $0.price < $1.price }
    }

    public func purchase() async {
        self.isBusy = true
        self.lastError = nil
        defer { self.isBusy = false }

        guard let session = await self.currentSession() else {
            self.lastError = PaidAccessError.notSignedIn.errorDescription
            return
        }
        if self.products.isEmpty {
            await self.loadProducts()
        }
        guard let product = self.products.first else {
            self.lastError = "Subscription products are not available in this build yet."
            return
        }

        do {
            let result = try await product.purchase()
            if case .success(let verification) = result {
                await self.syncIfSubscription(verification, session: session)
                if case .verified(let transaction) = verification {
                    await transaction.finish()
                }
                await self.refreshEntitlement()
            }
        } catch {
            self.lastError = "The purchase could not be completed."
        }
    }

    public func restorePurchases() async {
        self.isBusy = true
        defer { self.isBusy = false }

        guard let session = await self.currentSession() else {
            self.lastError = PaidAccessError.notSignedIn.errorDescription
            return
        }
        for await result in Transaction.currentEntitlements {
            await self.syncIfSubscription(result, session: session)
        }
        await self.refreshEntitlement()
    }

    /// Opens Apple's subscription management. App Store builds must never send
    /// the user to an external payment page.
    public func manageSubscription() {
        guard let url = URL(string: "https://apps.apple.com/account/subscriptions") else { return }
        UIApplication.shared.open(url)
    }

    private func handleTransactionUpdate(_ result: VerificationResult<Transaction>) async {
        guard let session = await self.currentSession() else { return }
        await self.syncIfSubscription(result, session: session)
        if case .verified(let transaction) = result {
            await transaction.finish()
        }
        await self.refreshEntitlement()
    }

    private func syncIfSubscription(
        _ result: VerificationResult<Transaction>,
        session: PaidAccessSession
    ) async {
        guard case .verified(let transaction) = result else { return }
        guard Self.subscriptionProductIDs.contains(transaction.productID) else { return }

        do {
            // The server verifies the signature again; the device's own
            // verification is never sufficient on its own.
            self.entitlement = try await self.client.syncStoreKitTransaction(
                session: session,
                signedTransaction: result.jwsRepresentation,
                signedRenewalInfo: nil
            )
        } catch {
            self.lastError = (error as? PaidAccessError)?.errorDescription
                ?? "Could not confirm the subscription."
        }
    }

    // MARK: - Nonce

    static func makeRawNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = (0..<32).map { _ in UInt8.random(in: UInt8.min...UInt8.max) }
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

// MARK: - Sign in with Apple delegates

extension PaidAccessStore: ASAuthorizationControllerDelegate {
    public func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        self.resumeSignIn(with: .success(authorization))
    }

    public func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        self.resumeSignIn(with: .failure(error))
    }
}

extension PaidAccessStore: ASAuthorizationControllerPresentationContextProviding {
    public func presentationAnchor(
        for controller: ASAuthorizationController
    ) -> ASPresentationAnchor {
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        return scene?.keyWindow ?? ASPresentationAnchor()
    }
}
#endif
