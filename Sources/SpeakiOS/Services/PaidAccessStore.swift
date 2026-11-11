#if os(iOS)
import AuthenticationServices
import Foundation
import SpeakCore
import StoreKit
import UIKit

/// Whether iOS can sell and use paid access at all.
///
/// **Paid routing is not wired up on iOS.** `PaidAccessStore` can hold a valid
/// entitlement and a routing policy, but nothing consults it when work is
/// actually dispatched — these call sites all go straight to the user's
/// own API key or an on-device model:
///
///   * `Sources/SpeakiOS/Services/iOSBatchTranscriber.swift`
///   * `Sources/SpeakiOS/Views/PostProcessingView.swift`
///
/// Selling a subscription in that state would charge for routing that does not
/// exist, and hiding the model pickers would strand the user with neither a
/// picker nor a paid route. So the purchase and routing UI is switched off
/// here, including automatic StoreKit observation. Routing those call
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

    // Mirrors of `flow.state`, published for SwiftUI.
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

    public static let subscriptionProductIDs = PaidSubscriptionTerm.productIDs

    /// The term the purchase button would buy. Explicit, so the yearly plan is
    /// reachable rather than losing to whichever product loaded first.
    @Published public var selectedTerm: PaidSubscriptionTerm = .monthly

    /// The session, entitlement, sign-in and StoreKit flow shared with macOS.
    let flow: PaidAccessFlow
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
        self.flow = PaidAccessFlow(client: client, sessionStore: sessionStore)
        self.simpleModelChoices = UserDefaults.standard.bool(forKey: "simpleModelChoices")
        self.paidRoutingEnabled = UserDefaults.standard.bool(forKey: "paidAccessRoutingEnabled")
        super.init()
        self.flow.onChange = { [weak self] state in self?.publish(state) }

        if PaidAccessFeature.isAvailableOnIOS {
            self.transactionListener = Task { [weak self] in
                for await update in Transaction.updates {
                    guard let self else { return }
                    guard PaidAccessFeature.isAvailableOnIOS else { continue }
                    await self.flow.handleTransactionUpdate(update)
                }
            }
        }
    }

    deinit {
        self.transactionListener?.cancel()
    }

    /// Mirrors the flow's state into the published properties.
    private func publish(_ state: PaidAccessFlowState) {
        if self.entitlement != state.entitlement { self.entitlement = state.entitlement }
        if self.policy != state.policy { self.policy = state.policy }
        if self.isSignedIn != state.isSignedIn { self.isSignedIn = state.isSignedIn }
        if self.isBusy != state.isBusy { self.isBusy = state.isBusy }
        if self.lastError != state.lastError { self.lastError = state.lastError }
        if self.products != state.products { self.products = state.products }
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

    // MARK: - Entitlement

    public func refreshEntitlement() async {
        await self.flow.refreshEntitlement()
    }

    // MARK: - Sign in with Apple

    public func signIn() async {
        // A second sign-in would overwrite `signInContinuation`, leaking the
        // first continuation and leaving `isBusy` stuck true for the session.
        guard self.signInContinuation == nil else { return }
        await self.flow.signIn(
            deviceLabel: UIDevice.current.name,
            identityToken: { [weak self] hashedNonce in
                guard let self else { throw CancellationError() }
                return try await self.appleIdentityToken(hashedNonce: hashedNonce)
            },
            errorMessage: Self.signInErrorMessage
        )
    }

    /// What to show for a failed sign-in; nil when the user dismissed the sheet.
    static func signInErrorMessage(_ error: Error) -> String? {
        switch error {
        case let error as ASAuthorizationError where error.code == .canceled:
            return nil
        case SignInError.missingIdentityToken:
            return "Apple did not return an identity token."
        default:
            return (error as? PaidAccessError)?.errorDescription ?? "Could not sign in with Apple."
        }
    }

    private enum SignInError: Error {
        case missingIdentityToken
    }

    private func appleIdentityToken(hashedNonce: String) async throws -> String {
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = hashedNonce
        let authorization = try await self.performAuthorization(for: request)
        guard
            let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
            let tokenData = credential.identityToken,
            let identityToken = String(data: tokenData, encoding: .utf8)
        else { throw SignInError.missingIdentityToken }
        return identityToken
    }

    public func signOut() async {
        await self.flow.signOut()
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
