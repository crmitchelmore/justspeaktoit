#if os(iOS)
import AuthenticationServices
import CryptoKit
import Foundation
import SpeakCore
import StoreKit
import UIKit

/// Whether iOS can sell and use paid access at all.
///
/// **Paid routing is not wired up on iOS.** `PaidAccessStore` can hold a valid
/// entitlement and a routing policy, but nothing consults it when work is
/// actually dispatched — these three call sites all go straight to the user's
/// own API key or an on-device model:
///
///   * `Sources/SpeakiOS/Services/iOSBatchTranscriber.swift`
///   * `Sources/SpeakiOS/Services/VoiceSummariser.swift`
///   * `Sources/SpeakiOS/Views/PostProcessingView.swift`
///
/// Selling a subscription in that state would charge for routing that does not
/// exist, and hiding the model pickers would strand the user with neither a
/// picker nor a paid route. So the purchase and routing UI is switched off
/// here, and the code below stays compiled so that wiring those three call
/// sites through a proxy client — as macOS does with `PaidAccessProxyClient` —
/// plus flipping this one constant, is the whole change.
public enum PaidAccessFeature {
    /// Flip to `true` in the same change that routes the three call sites above
    /// through the paid service.
    public static let isAvailableOnIOS = false
}

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

    public static let shared = PaidAccessStore()

    // `internal(set)` rather than `private(set)` on the four below: the StoreKit
    // half of this type lives in `PaidAccessStore+Purchase.swift` and Swift
    // scopes `private` to the file. Still read-only to anything outside SpeakiOS.
    @Published public internal(set) var entitlement: PaidEntitlement = .unentitled
    @Published public private(set) var policy: PaidRoutingPolicy = .unknown
    @Published public private(set) var isSignedIn = false
    @Published public internal(set) var isBusy = false
    @Published public internal(set) var lastError: String?
    @Published public internal(set) var products: [Product] = []

    /// Mirrors the macOS setting: hides the model pickers and lets the
    /// subscription pick the best model for each task.
    @Published public var simpleModelChoices: Bool {
        didSet { UserDefaults.standard.set(simpleModelChoices, forKey: "simpleModelChoices") }
    }

    /// Off by default, and ignored without a verified entitlement.
    @Published public var paidRoutingEnabled: Bool {
        didSet { UserDefaults.standard.set(paidRoutingEnabled, forKey: "paidAccessRoutingEnabled") }
    }

    public static let subscriptionProductIDs = PaidSubscriptionTerm.productIDs

    /// The term the purchase button would buy. Explicit, so the yearly plan is
    /// reachable rather than losing to whichever product loaded first.
    @Published public var selectedTerm: PaidSubscriptionTerm = .monthly

    let client: any PaidAccessClienting
    private let sessionStore: any PaidAccessSessionStoring
    private var transactionListener: Task<Void, Never>?
    private var refreshTask: Task<PaidAccessSession?, Never>?
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

    /// Reports no paid routing while ``PaidAccessFeature/isAvailableOnIOS`` is
    /// off, so the model pickers stay visible even for a subscriber who bought
    /// on a Mac. Without that, an entitled iPhone would hide the pickers and
    /// then transcribe with the user's own key anyway.
    public var simpleModelChoicesPolicy: SimpleModelChoicesPolicy {
        SimpleModelChoicesPolicy(
            isEnabled: self.simpleModelChoices,
            hasPaidRouting: PaidAccessFeature.isAvailableOnIOS
                && self.entitlement.allowsPaidRouting()
        )
    }

    public var isPaidRoutingActive: Bool {
        PaidAccessFeature.isAvailableOnIOS
            && self.paidRoutingEnabled
            && self.entitlement.allowsPaidRouting()
    }

    public var router: PaidAccessRouter {
        PaidAccessRouter(
            entitlement: self.entitlement,
            policy: self.policy,
            isPaidRoutingPreferred: self.paidRoutingEnabled
        )
    }

    // MARK: - Session

    /// Internal rather than private: `PaidAccessStore+Purchase.swift` needs it,
    /// and Swift scopes `private` to the file.
    func currentSession() async -> PaidAccessSession? {
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

        // `@MainActor` isolation does not survive the await below, so without a
        // single-flight task two concurrent callers would each present the same
        // refresh token and the server's reuse detection would sign the user out.
        if let inFlight = self.refreshTask {
            return await inFlight.value
        }
        let task = Task { [client, sessionStore] () -> PaidAccessSession? in
            do {
                let refreshed = try await client.refresh(session: stored)
                try await sessionStore.saveSession(refreshed)
                return refreshed
            } catch PaidAccessError.notSignedIn {
                return nil
            } catch {
                return stored
            }
        }
        self.refreshTask = task
        let result = await task.value
        self.refreshTask = nil
        if result == nil {
            await self.clearSession()
        }
        return result
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
            // Entitlement and policy are committed together: a second, separate
            // policy call could fail and leave an active entitlement with an
            // empty policy, which routes nothing.
            let state = try await self.client.entitlement(session: session)
            self.entitlement = state.entitlement
            self.policy = state.policy
            self.lastError = nil
        } catch PaidAccessError.notSignedIn {
            await self.clearSession()
        } catch {
            self.lastError = (error as? PaidAccessError)?.errorDescription
        }
    }

    // MARK: - Sign in with Apple

    public func signIn() async {
        // A second sign-in would overwrite `signInContinuation`, leaking the
        // first continuation and leaving `isBusy` stuck true for the session.
        guard self.signInContinuation == nil, !self.isBusy else { return }
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
        guard self.signInContinuation == nil else {
            throw PaidAccessError.network("A sign-in is already in progress.")
        }
        return try await withCheckedThrowingContinuation { continuation in
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
