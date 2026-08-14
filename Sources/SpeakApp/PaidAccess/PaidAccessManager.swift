import AppKit
import AuthenticationServices
import CryptoKit
import Foundation
import SpeakCore
import StoreKit

// swiftlint:disable file_length

/// Owns the paid-access session, entitlement and purchase flows on macOS.
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
final class PaidAccessManager: NSObject, ObservableObject { // swiftlint:disable:this type_body_length

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
  private let sessionStore: any PaidAccessSessionStoring
  private let settings: AppSettings
  private var transactionListener: Task<Void, Never>?
  private var refreshTask: Task<PaidAccessSession?, Never>?
  private var launchRestore: Task<Void, Never>?
  private var hasFinishedLaunchRestore = false
  private var launchRestoreWaiters: [CheckedContinuation<Void, Never>] = []
  private var signInContinuation: CheckedContinuation<ASAuthorization, Error>?

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
    self.sessionStore = sessionStore
    self.settings = settings
    super.init()

    if self.billingChannel == .storeKit {
      // Renewals, refunds and family-sharing changes arrive here without any
      // user action, so the entitlement stays correct between launches.
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

  var billingChannel: PaidBillingChannel {
    DistributionChannel.current.paidBillingChannel
  }

  var simpleModelChoicesPolicy: SimpleModelChoicesPolicy {
    SimpleModelChoicesPolicy(
      isEnabled: self.settings.simpleModelChoices,
      hasPaidRouting: self.entitlement.allowsPaidRouting()
    )
  }

  var router: PaidAccessRouter {
    PaidAccessRouter(
      entitlement: self.entitlement,
      policy: self.policy,
      isPaidRoutingPreferred: self.settings.paidAccessRoutingEnabled
    )
  }

  /// Whether paid routing is genuinely in effect right now.
  var isPaidRoutingActive: Bool {
    self.settings.paidAccessRoutingEnabled && self.entitlement.allowsPaidRouting()
  }

  // MARK: - Session handling

  /// Returns a usable session, rotating the refresh token when the access token
  /// is close to expiry. Returns `nil` when the user is not signed in.
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
        // A transient refresh failure must not sign the user out; the stored
        // session may still work, and if it does not the caller falls back.
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

  /// Session accessor for the proxy client. Never surfaces errors — an absent
  /// session simply means "use the user's own configuration".
  nonisolated func sessionProvider() -> @Sendable () async -> PaidAccessSession? {
    { [weak self] in
      guard let self else { return nil }
      return await self.currentSession()
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
    guard let session = await self.currentSession() else {
      self.entitlement = .unentitled
      self.policy = .unknown
      return
    }

    do {
      // One call, one commit. Fetching the policy separately could leave an
      // active entitlement paired with an empty policy — entitled, with
      // nowhere to send the request — if the second call failed.
      let state = try await self.client.entitlement(session: session)
      self.entitlement = state.entitlement
      self.policy = state.policy
      self.lastError = nil
    } catch PaidAccessError.notSignedIn {
      await self.clearSession()
    } catch {
      // Keep the last known entitlement so a brief outage does not flip the UI
      // to "not subscribed"; routing still re-checks expiry locally.
      self.lastError = (error as? PaidAccessError)?.errorDescription
    }
  }

  // MARK: - Sign in with Apple

  func signIn() async {
    // A second sign-in would overwrite `signInContinuation`, leaking the first
    // continuation and leaving `isBusy` stuck true for the rest of the launch.
    guard self.signInContinuation == nil, !self.isBusy else { return }
    self.isBusy = true
    self.lastError = nil
    defer { self.isBusy = false }

    let rawNonce = Self.makeRawNonce()
    let request = ASAuthorizationAppleIDProvider().createRequest()
    request.requestedScopes = [.fullName, .email]
    // Apple echoes this hashed value back in the identity token; the server is
    // given the raw nonce and re-derives the digest, which is what binds the
    // token to this specific request.
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
        deviceLabel: Host.current().localizedName
      )
      try await self.sessionStore.saveSession(session)
      self.isSignedIn = true
      await self.refreshEntitlement()
    } catch is CancellationError {
      // The user dismissed the sheet; not an error worth showing.
    } catch let error as ASAuthorizationError where error.code == .canceled {
      // Same.
    } catch {
      self.lastError = (error as? PaidAccessError)?.errorDescription
        ?? "Could not sign in with Apple."
    }
  }

  func signOut() async {
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

  // MARK: - Purchase

  /// Buys the named term.
  ///
  /// - Parameter term: Which subscription to buy. Defaults to the user's
  ///   current choice rather than to whichever product loaded first.
  func purchase(term: PaidSubscriptionTerm? = nil) async {
    let term = term ?? self.selectedTerm
    self.isBusy = true
    self.lastError = nil
    defer { self.isBusy = false }

    guard let session = await self.currentSession() else {
      self.lastError = PaidAccessError.notSignedIn.errorDescription
      return
    }

    switch self.billingChannel {
    case .stripeCheckout:
      do {
        let url = try await self.client.createCheckoutURL(session: session)
        NSWorkspace.shared.open(url)
      } catch {
        self.lastError = (error as? PaidAccessError)?.errorDescription
          ?? "Could not start checkout."
      }

    case .storeKit:
      await self.purchaseThroughStoreKit(term: term, session: session)
    }
  }

  func manageSubscription() async {
    self.isBusy = true
    defer { self.isBusy = false }

    switch self.billingChannel {
    case .stripeCheckout:
      guard let session = await self.currentSession() else {
        self.lastError = PaidAccessError.notSignedIn.errorDescription
        return
      }
      do {
        let url = try await self.client.createBillingPortalURL(session: session)
        NSWorkspace.shared.open(url)
      } catch {
        self.lastError = (error as? PaidAccessError)?.errorDescription
          ?? "Could not open the billing portal."
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
    self.isBusy = true
    defer { self.isBusy = false }

    guard self.billingChannel == .storeKit else {
      await self.refreshEntitlement()
      return
    }
    guard let session = await self.currentSession() else {
      self.lastError = PaidAccessError.notSignedIn.errorDescription
      return
    }

    for await result in Transaction.currentEntitlements {
      await self.syncIfSubscription(result, session: session)
    }
    await self.refreshEntitlement()
  }

  func loadProducts() async {
    guard self.billingChannel == .storeKit else { return }
    let loaded = try? await Product.products(for: Self.subscriptionProductIDs)
    self.products = (loaded ?? []).sorted { $0.price < $1.price }
  }

  /// The loaded StoreKit product for a term, if the App Store returned it.
  func product(for term: PaidSubscriptionTerm) -> Product? {
    self.products.first { $0.id == term.productID }
  }

  private func purchaseThroughStoreKit(
    term: PaidSubscriptionTerm,
    session: PaidAccessSession
  ) async {
    if self.products.isEmpty {
      await self.loadProducts()
    }
    // Matched by product id, never by position: `products.first` bought the
    // cheapest loaded product whatever the user had chosen.
    guard let product = self.product(for: term) else {
      self.lastError = "The \(term.displayName.lowercased()) subscription is not available in this build yet."
      return
    }

    // Bind the purchase to this account before it happens. The server rejects a
    // signed transaction whose `appAccountToken` is not the caller's, so a
    // purchase made without one produces a receipt nobody can redeem.
    guard let accountToken = session.storeKitAccountToken else {
      self.lastError = "This account cannot be linked to an App Store purchase. Sign out, sign back in and try again."
      return
    }

    do {
      let result = try await product.purchase(options: [.appAccountToken(accountToken)])
      switch result {
      case .success(let verification):
        if
          await self.syncIfSubscription(verification, session: session),
          case .verified(let transaction) = verification
        {
          await transaction.finish()
        }
        await self.refreshEntitlement()
      case .userCancelled, .pending:
        break
      @unknown default:
        break
      }
    } catch {
      self.lastError = "The purchase could not be completed."
    }
  }

  private func handleTransactionUpdate(_ result: VerificationResult<Transaction>) async {
    guard let session = await self.currentSession() else { return }
    if
      await self.syncIfSubscription(result, session: session),
      case .verified(let transaction) = result
    {
      await transaction.finish()
    }
    await self.refreshEntitlement()
  }

  /// Sends a signed transaction to the server for verification.
  ///
  /// Only locally verified subscription transactions are forwarded, and the
  /// server verifies the signature again regardless — the device's verdict is
  /// never trusted on its own.
  private func syncIfSubscription(
    _ result: VerificationResult<Transaction>,
    session: PaidAccessSession
  ) async -> Bool {
    guard case .verified(let transaction) = result else { return false }
    guard Self.subscriptionProductIDs.contains(transaction.productID) else { return false }

    do {
      self.entitlement = try await self.client.syncStoreKitTransaction(
        session: session,
        signedTransaction: result.jwsRepresentation,
        signedRenewalInfo: nil
      )
      return true
    } catch {
      self.lastError = (error as? PaidAccessError)?.errorDescription
        ?? "Could not confirm the subscription."
      return false
    }
  }

  // MARK: - Nonce

  /// 32 bytes of entropy, URL-safe. Sign in with Apple replays this back to us
  /// so a captured identity token cannot be replayed against a different request.
  static func makeRawNonce() -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    if status != errSecSuccess {
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

extension PaidAccessManager: ASAuthorizationControllerDelegate {
  func authorizationController(
    controller: ASAuthorizationController,
    didCompleteWithAuthorization authorization: ASAuthorization
  ) {
    self.resumeSignIn(with: .success(authorization))
  }

  func authorizationController(
    controller: ASAuthorizationController,
    didCompleteWithError error: Error
  ) {
    self.resumeSignIn(with: .failure(error))
  }
}

extension PaidAccessManager: ASAuthorizationControllerPresentationContextProviding {
  func presentationAnchor(
    for controller: ASAuthorizationController
  ) -> ASPresentationAnchor {
    NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? NSWindow()
  }
}
