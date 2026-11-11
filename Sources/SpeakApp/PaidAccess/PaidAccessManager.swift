import AppKit
import AuthenticationServices
import Foundation
import SpeakCore
import StoreKit

/// Build-time gate for the subscription surface and paid routing.
///
/// Normal release generation does not define `PAID_ACCESS`, making both the UI
/// and routing inert. Chris/internal builds opt in with
/// `TUIST_PAID_ACCESS=1 tuist generate`.
enum PaidAccessFeature {
  #if PAID_ACCESS
  static let isEnabled = true
  #else
  static let isEnabled = false
  #endif

  static var baseURL: URL {
    #if PAID_ACCESS
    if let override = ProcessInfo.processInfo.environment["PAID_ACCESS_BASE_URL"],
       let url = URL(string: override),
       let scheme = url.scheme,
       ["http", "https"].contains(scheme) {
      return url
    }
    #endif
    return PaidAccessHTTPClient.defaultBaseURL
  }
}

/// Owns the paid-access session, entitlement and purchase flows on macOS.
/// The shared state machine is SpeakCore's `PaidAccessFlow`; this type adds
/// the Mac's billing channels (StoreKit or Stripe checkout), Apple's web
/// sign-in for direct-download builds, and the launch-time restore.
///
/// Two rules shape this type:
///
///   * The app never decides whether it is entitled. It presents evidence
///     (an Apple identity token, a StoreKit signed transaction) and reads back
///     the server's verdict.
///   * Nothing here is required for dictation. Every failure leaves the app on
///     the user's own API keys or local models, which is what the subscription
///     is an alternative to — not a prerequisite for.
@MainActor
final class PaidAccessManager: NSObject, ObservableObject {

  @Published private(set) var entitlement: PaidEntitlement = .unentitled
  @Published private(set) var policy: PaidRoutingPolicy = .unknown
  @Published private(set) var isSignedIn: Bool = false
  @Published private(set) var isBusy: Bool = false
  @Published private(set) var lastError: String?
  @Published private(set) var products: [Product] = []

  /// The term the purchase button will buy. Held here rather than in the view
  /// so the choice is explicit, testable, and impossible to skip: the flow used
  /// to buy whichever product loaded first, which made the yearly plan
  /// unreachable.
  @Published var selectedTerm: PaidSubscriptionTerm = .monthly

  private let client: any PaidAccessClienting
  private let flow: PaidAccessFlow
  private let settings: AppSettings
  private var transactionListener: Task<Void, Never>?
  private var launchRestore: Task<Void, Never>?
  private var hasFinishedLaunchRestore = false
  private var launchRestoreWaiters: [CheckedContinuation<Void, Never>] = []
  private let appleIDAuthorization = AppleIDAuthorization()

  /// Direct-download (Developer ID) builds cannot use native Sign in with
  /// Apple, so they use Apple's web flow; App Store builds stay native.
  var usesWebSignIn = DistributionChannel.current.paidBillingChannel == .stripeCheckout
  /// Presents Apple's web sign-in and returns the relayed callback URL.
  /// Replaced in tests, which have no browser.
  var webAuthenticator: @MainActor (URL, String) async throws -> URL = { url, scheme in
    try await AppleWebSignIn.authenticate(url: url, callbackScheme: scheme)
  }

  /// How long a request will wait for the launch-time entitlement restore
  /// before proceeding without it. Long enough for a Keychain read and one
  /// round trip on a normal connection, short enough that a subscriber on a
  /// dead network still dictates promptly through their own configuration.
  private static let launchRestoreGrace: TimeInterval = 3

  /// Subscription products offered by App Store builds.
  static let subscriptionProductIDs = PaidSubscriptionTerm.productIDs

  init(
    client: any PaidAccessClienting,
    sessionStore: any PaidAccessSessionStoring,
    settings: AppSettings
  ) {
    self.client = client
    self.flow = PaidAccessFlow(client: client, sessionStore: sessionStore)
    self.settings = settings
    super.init()
    self.flow.onChange = { [weak self] state in self?.publish(state) }

    if PaidAccessFeature.isEnabled && self.billingChannel == .storeKit {
      // Renewals, refunds and family-sharing changes arrive here without any
      // user action, so the entitlement stays correct between launches.
      self.transactionListener = Task { [weak self] in
        for await update in Transaction.updates {
          guard let self else { return }
          guard PaidAccessFeature.isEnabled else { continue }
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

  var billingChannel: PaidBillingChannel {
    DistributionChannel.current.paidBillingChannel
  }

  var simpleModelChoicesPolicy: SimpleModelChoicesPolicy {
    SimpleModelChoicesPolicy(
      isEnabled: self.settings.simpleModelChoices,
      hasPaidRouting: self.isPaidRoutingActive
    )
  }

  var router: PaidAccessRouter {
    PaidAccessRouter(
      entitlement: self.entitlement,
      policy: self.policy,
      isPaidRoutingPreferred: PaidAccessFeature.isEnabled && self.settings.paidAccessRoutingEnabled
    )
  }

  /// Whether paid routing is genuinely in effect right now.
  var isPaidRoutingActive: Bool {
    PaidAccessFeature.isEnabled
      && self.settings.paidAccessRoutingEnabled
      && self.entitlement.allowsPaidRouting()
  }

  // MARK: - Session handling

  /// Session accessor for the proxy client. Never surfaces errors — an absent
  /// session simply means "use the user's own configuration".
  nonisolated func sessionProvider() -> @Sendable () async -> PaidAccessSession? {
    { [weak self] in
      guard let self else { return nil }
      return await self.flow.currentSession()
    }
  }

  nonisolated func routerProvider() -> @Sendable () async -> PaidAccessRouter {
    { [weak self] in
      guard let self else {
        return PaidAccessRouter(
          entitlement: .unentitled,
          policy: .unknown,
          isPaidRoutingPreferred: false
        )
      }
      await self.awaitLaunchRestore()
      return await self.router
    }
  }

  // MARK: - Launch restore

  /// Loads a stored subscription once, at launch, so paid routing works without
  /// opening Settings first. Reads the Keychain and returns immediately when no
  /// session is stored, so users who never subscribed do no network work.
  func restoreEntitlementAtLaunch() {
    guard self.launchRestore == nil else { return }
    self.launchRestore = Task { [weak self] in
      await self?.refreshEntitlement()
      self?.finishLaunchRestore()
    }
  }

  /// Holds the first routing decision after launch until the stored entitlement
  /// has loaded. Without this a subscriber's first dictation races the restore
  /// and falls back to their own key, which they may not have configured.
  ///
  /// Bounded on purpose: paid access is an alternative to the user's own keys,
  /// never a prerequisite, so a slow or failed restore gives up rather than
  /// holding dictation open.
  private func awaitLaunchRestore() async {
    guard self.launchRestore != nil, !self.hasFinishedLaunchRestore else { return }

    let expiry = Task { [weak self] in
      try? await Task.sleep(for: .seconds(Self.launchRestoreGrace))
      guard !Task.isCancelled else { return }
      self?.finishLaunchRestore()
    }
    await withCheckedContinuation { continuation in
      self.launchRestoreWaiters.append(continuation)
    }
    expiry.cancel()
  }

  private func finishLaunchRestore() {
    guard !self.hasFinishedLaunchRestore else { return }
    self.hasFinishedLaunchRestore = true
    let waiters = self.launchRestoreWaiters
    self.launchRestoreWaiters = []
    for waiter in waiters {
      waiter.resume()
    }
  }

  // MARK: - Entitlement

  func refreshEntitlement() async {
    await self.flow.refreshEntitlement()
  }

  // MARK: - Sign in with Apple

  func signIn() async {
    // A second sign-in would leave `isBusy` stuck true for the rest of the launch.
    guard !self.appleIDAuthorization.isInProgress else { return }
    await self.flow.signIn(
      deviceLabel: Host.current().localizedName,
      identityToken: { [weak self] hashedNonce in
        guard let self else { throw CancellationError() }
        return try await self.appleIdentityToken(hashedNonce: hashedNonce)
      },
      errorMessage: Self.signInErrorMessage
    )
  }

  /// What to show for a failed sign-in; nil when the user simply dismissed it.
  static func signInErrorMessage(_ error: Error) -> String? {
    switch error {
    case is CancellationError, AppleWebSignIn.CallbackError.cancelled:
      return nil
    case let error as ASAuthorizationError where error.code == .canceled:
      return nil
    case is AppleWebSignIn.CallbackError:
      return "Apple did not return an identity token."
    default:
      return (error as? PaidAccessError)?.errorDescription ?? "Could not sign in with Apple."
    }
  }

  func signOut() async {
    await self.flow.signOut()
  }

  /// One Apple identity token for `hashedNonce`, from the native sheet or,
  /// on direct-download builds, Apple's web flow.
  private func appleIdentityToken(hashedNonce: String) async throws -> String {
    if self.usesWebSignIn {
      // `state` ties the relayed callback to this attempt.
      let state = PaidAccessNonce.makeRaw()
      let url = AppleWebSignIn.authorizationURL(state: state, hashedNonce: hashedNonce)
      let callback = try await self.webAuthenticator(url, AppleWebSignIn.callbackScheme)
      return try AppleWebSignIn.identityToken(from: callback, expectedState: state)
    }
    return try await self.appleIDAuthorization.identityToken(hashedNonce: hashedNonce)
  }

  // MARK: - Purchase

  /// Buys the named term.
  ///
  /// - Parameter term: Which subscription to buy. Defaults to the user's
  ///   current choice rather than to whichever product loaded first.
  func purchase(term: PaidSubscriptionTerm? = nil) async {
    let term = term ?? self.selectedTerm
    await self.flow.withSignedInOperation(clearingError: true) { session, generation in
      switch self.billingChannel {
      case .stripeCheckout:
        do {
          let url = try await self.client.createCheckoutURL(session: session)
          guard generation == self.flow.generation else { return }
          NSWorkspace.shared.open(url)
        } catch {
          self.flow.report((error as? PaidAccessError)?.errorDescription ?? "Could not start checkout.")
        }
      case .storeKit:
        await self.flow.purchaseThroughStoreKit(term: term, session: session, generation: generation)
      }
    }
  }

  func manageSubscription() async {
    let operation = self.flow.beginOperation(clearingError: false)
    defer { self.flow.endOperation(operation) }

    if self.entitlement.provider == .manual {
      self.flow.report("This access was granted manually and has no subscription to manage.")
      return
    }
    if self.entitlement.provider == .stripe && self.billingChannel == .storeKit {
      self.flow.report(
        "This subscription was purchased on the website. Manage it in your Just Speak to It web account."
      )
      return
    }
    switch self.entitlement.provider == .storeKit ? PaidBillingChannel.storeKit : .stripeCheckout {
    case .stripeCheckout:
      let generation = self.flow.generation
      guard let session = await self.flow.currentSession() else {
        self.flow.report(PaidAccessError.notSignedIn.errorDescription)
        return
      }
      do {
        let url = try await self.client.createBillingPortalURL(session: session)
        guard generation == self.flow.generation else { return }
        NSWorkspace.shared.open(url)
      } catch {
        self.flow.report((error as? PaidAccessError)?.errorDescription ?? "Could not open the billing portal.")
      }

    case .storeKit:
      let subscriptions = URL(string: "macappstores://apps.apple.com/account/subscriptions")
      let fallback = URL(string: "https://apps.apple.com/account/subscriptions")
      if let url = subscriptions ?? fallback {
        NSWorkspace.shared.open(url)
      }
    }
  }

  func restorePurchases() async {
    guard self.billingChannel == .storeKit else {
      let operation = self.flow.beginOperation(clearingError: false)
      defer { self.flow.endOperation(operation) }
      await self.flow.refreshEntitlement()
      return
    }
    await self.flow.withSignedInOperation(clearingError: false) { session, generation in
      await self.flow.restoreStoreKitPurchases(session: session, generation: generation)
    }
  }

  func loadProducts() async {
    guard self.billingChannel == .storeKit else { return }
    await self.flow.loadProducts()
  }

  /// The loaded StoreKit product for a term, if the App Store returned it.
  func product(for term: PaidSubscriptionTerm) -> Product? {
    self.flow.product(for: term)
  }
}
