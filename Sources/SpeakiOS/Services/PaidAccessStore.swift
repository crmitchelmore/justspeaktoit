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
/// here, including automatic StoreKit observation. Routing those three call
/// sites through a proxy client is still required. Supported identity, signing,
/// products and staging qualification are separate commissioning gates.
public enum PaidAccessFeature {
    /// Keep disabled until routing and the separate commissioning gates pass.
    public static let isAvailableOnIOS = false
}

/// Paid-access state for iOS.
///
/// iOS always ships through the App Store, so billing is always StoreKit; the
/// Stripe path exists only for the direct-download Mac build. Identity is
/// represented by the same server account contract across channels; supported
/// sign-in flows and cross-channel entitlement access remain uncommissioned.
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
    let sessions: PaidAccessSessionLifecycle
    var busyOperation = UUID()
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
        self.sessions = PaidAccessSessionLifecycle(client: client, store: sessionStore)
        self.simpleModelChoices = UserDefaults.standard.bool(forKey: "simpleModelChoices")
        self.paidRoutingEnabled = UserDefaults.standard.bool(forKey: "paidAccessRoutingEnabled")
        super.init()

        if PaidAccessFeature.isAvailableOnIOS {
            self.transactionListener = Task { [weak self] in
                for await update in Transaction.updates {
                    guard let self else { return }
                    await self.handleTransactionUpdate(update)
                }
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
            hasPaidRouting: self.isPaidRoutingActive
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
            // Same feature-flag guard as isPaidRoutingActive: while iOS paid
            // routing is unwired, no accessor may prefer the paid rail.
            isPaidRoutingPreferred: PaidAccessFeature.isAvailableOnIOS && self.paidRoutingEnabled
        )
    }

    // MARK: - Session

    /// Internal rather than private: `PaidAccessStore+Purchase.swift` needs it,
    /// and Swift scopes `private` to the file.
    func currentSession() async -> PaidAccessSession? {
        let generation = self.sessions.generation
        do {
            let session = try await self.sessions.currentSession()
            guard generation == self.sessions.generation else { return nil }
            self.isSignedIn = session != nil
            if session == nil {
                // An empty store is not another logout: sign-in may be awaiting Apple.
                self.entitlement = .unentitled
                self.policy = .unknown
            }
            return session
        } catch {
            guard generation == self.sessions.generation else { return nil }
            await self.clearSession()
            return nil
        }
    }

    private func clearSession() async {
        let clearing = self.sessions.clear()
        self.isSignedIn = false
        self.entitlement = .unentitled
        self.policy = .unknown
        _ = await clearing.value
    }

    // MARK: - Entitlement

    public func refreshEntitlement() async {
        let generation = self.sessions.generation
        guard let session = await self.currentSession() else {
            guard generation == self.sessions.generation else { return }
            self.entitlement = .unentitled
            self.policy = .unknown
            return
        }

        do {
            // Entitlement and policy are committed together: a second, separate
            // policy call could fail and leave an active entitlement with an
            // empty policy, which routes nothing.
            let state = try await self.client.entitlement(session: session)
            guard generation == self.sessions.generation else { return }
            self.entitlement = state.entitlement
            self.policy = state.policy
            self.lastError = nil
        } catch PaidAccessError.notSignedIn {
            guard generation == self.sessions.generation else { return }
            await self.clearSession()
        } catch {
            guard generation == self.sessions.generation else { return }
            self.lastError = (error as? PaidAccessError)?.errorDescription
        }
    }

    // MARK: - Sign in with Apple

    public func signIn() async {
        // A second sign-in would overwrite `signInContinuation`, leaking the
        // first continuation and leaving `isBusy` stuck true for the session.
        guard self.signInContinuation == nil, !self.isBusy else { return }
        let clearing = self.sessions.clear()
        let generation = self.sessions.generation
        self.isSignedIn = false
        self.entitlement = .unentitled
        self.policy = .unknown
        let operation = UUID()
        self.busyOperation = operation
        self.isBusy = true
        self.lastError = nil
        defer { if operation == self.busyOperation { self.isBusy = false } }

        _ = await clearing.value
        guard generation == self.sessions.generation else { return }

        let rawNonce = Self.makeRawNonce()
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = Self.sha256Hex(rawNonce)

        do {
            let authorization = try await self.performAuthorization(for: request)
            guard generation == self.sessions.generation else { return }
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
            guard let signedInGeneration = try await self.sessions.acceptSignIn(session, generation: generation),
                signedInGeneration == self.sessions.generation
            else { return }
            self.isSignedIn = true
            await self.refreshEntitlement()
        } catch let error as ASAuthorizationError where error.code == .canceled {
            // The user dismissed the sheet.
        } catch {
            guard generation == self.sessions.generation else { return }
            self.lastError =
                (error as? PaidAccessError)?.errorDescription
                ?? "Could not sign in with Apple."
        }
    }

    public func signOut() async {
        let clearing = self.sessions.clear()
        self.isSignedIn = false
        self.entitlement = .unentitled
        self.policy = .unknown
        let operation = UUID()
        self.busyOperation = operation
        self.isBusy = true
        defer { if operation == self.busyOperation { self.isBusy = false } }

        // Clear local credentials first. A slow revocation must never clear a
        // replacement account or restore state from an earlier refresh.
        if let session = await clearing.value {
            await self.client.signOut(session: session)
        }
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
