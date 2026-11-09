import AppKit
import AuthenticationServices
import Foundation
import SpeakCore

/// Sign in with Apple through Apple's web flow, for the direct-download Mac app.
///
/// Native Sign in with Apple is unavailable to Developer ID builds, so the app
/// opens Apple's authorisation page in an `ASWebAuthenticationSession`. Apple
/// form-posts the identity token to the paid-access Worker's return URL, which
/// relays it to `callbackScheme`. The token is then exchanged exactly like the
/// native one: the server checks the Services ID audience and the nonce.
enum AppleWebSignIn {
  /// Services ID registered in the Apple Developer portal for this flow; it is
  /// the identity token's audience and must be in `APPLE_IDENTITY_AUDIENCES`.
  static let servicesID = "com.justspeaktoit.mac.signin"
  /// The return URL registered for the Services ID.
  static let redirectURI = URL(string: "https://api.justspeaktoit.com/v1/auth/apple/callback")!
  /// Private scheme the Worker redirects to; only this session receives it.
  static let callbackScheme = "justspeaktoit-auth"
  static let callbackHost = "apple-callback"

  /// Apple's authorisation URL for one attempt. `form_post` is required
  /// whenever name or email scopes are requested.
  static func authorizationURL(state: String, hashedNonce: String) -> URL {
    var components = URLComponents(string: "https://appleid.apple.com/auth/authorize")!
    components.queryItems = [
      URLQueryItem(name: "client_id", value: self.servicesID),
      URLQueryItem(name: "redirect_uri", value: self.redirectURI.absoluteString),
      URLQueryItem(name: "response_type", value: "code id_token"),
      URLQueryItem(name: "response_mode", value: "form_post"),
      URLQueryItem(name: "scope", value: "name email"),
      URLQueryItem(name: "state", value: state),
      URLQueryItem(name: "nonce", value: hashedNonce)
    ]
    return components.url!
  }

  enum CallbackError: Error, Equatable {
    case cancelled
    case stateMismatch
    case failed
  }

  /// Extracts the identity token from the relayed callback, refusing any
  /// callback that is not for this attempt.
  static func identityToken(from callback: URL, expectedState: String) throws -> String {
    guard
      callback.scheme == self.callbackScheme,
      callback.host == self.callbackHost,
      let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems
    else { throw CallbackError.failed }
    func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
    guard let state = value("state"), state == expectedState else { throw CallbackError.stateMismatch }
    if let error = value("error") {
      throw error == "cancelled" ? CallbackError.cancelled : CallbackError.failed
    }
    guard let token = value("id_token"), !token.isEmpty else { throw CallbackError.failed }
    return token
  }

  /// Runs the browser session and returns the callback URL.
  @MainActor
  static func authenticate(url: URL, callbackScheme: String) async throws -> URL {
    try await WebAuthenticationRun().start(url: url, callbackScheme: callbackScheme)
  }
}

/// Owns one browser session until it completes: `ASWebAuthenticationSession`
/// is cancelled if released, and holds its presentation provider weakly.
@MainActor
private final class WebAuthenticationRun: NSObject, ASWebAuthenticationPresentationContextProviding {
  private var session: ASWebAuthenticationSession?

  func start(url: URL, callbackScheme: String) async throws -> URL {
    try await withCheckedThrowingContinuation { continuation in
      let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { callback, error in
        if let callback {
          continuation.resume(returning: callback)
        } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
          continuation.resume(throwing: AppleWebSignIn.CallbackError.cancelled)
        } else {
          continuation.resume(throwing: error ?? AppleWebSignIn.CallbackError.failed)
        }
        Task { @MainActor in self.session = nil }
      }
      session.presentationContextProvider = self
      self.session = session
      if !session.start() {
        self.session = nil
        continuation.resume(throwing: AppleWebSignIn.CallbackError.failed)
      }
    }
  }

  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? NSWindow()
  }
}
