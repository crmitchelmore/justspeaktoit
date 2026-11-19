import AppKit
import AuthenticationServices
import Foundation
import SpeakCore

/// Runs one native Sign in with Apple sheet at a time and hands back its
/// identity token. Owns the single authorisation continuation so a second
/// request can never overwrite (and leak) the first.
@MainActor
final class AppleIDAuthorization: NSObject {
  private var continuation: CheckedContinuation<ASAuthorization, Error>?

  var isInProgress: Bool { self.continuation != nil }

  func identityToken(hashedNonce: String) async throws -> String {
    let request = ASAuthorizationAppleIDProvider().createRequest()
    request.requestedScopes = [.fullName, .email]
    request.nonce = hashedNonce
    let authorization = try await self.perform(request)
    guard
      let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
      let tokenData = credential.identityToken,
      let identityToken = String(data: tokenData, encoding: .utf8)
    else { throw AppleWebSignIn.CallbackError.failed }
    return identityToken
  }

  private func perform(_ request: ASAuthorizationAppleIDRequest) async throws -> ASAuthorization {
    guard self.continuation == nil else {
      throw PaidAccessError.network("A sign-in is already in progress.")
    }
    return try await withCheckedThrowingContinuation { continuation in
      self.continuation = continuation
      let controller = ASAuthorizationController(authorizationRequests: [request])
      controller.delegate = self
      controller.presentationContextProvider = self
      controller.performRequests()
    }
  }

  private func resume(with result: Result<ASAuthorization, Error>) {
    guard let continuation = self.continuation else { return }
    self.continuation = nil
    continuation.resume(with: result)
  }
}

extension AppleIDAuthorization: ASAuthorizationControllerDelegate {
  func authorizationController(
    controller: ASAuthorizationController,
    didCompleteWithAuthorization authorization: ASAuthorization
  ) {
    self.resume(with: .success(authorization))
  }

  func authorizationController(
    controller: ASAuthorizationController,
    didCompleteWithError error: Error
  ) {
    self.resume(with: .failure(error))
  }
}

extension AppleIDAuthorization: ASAuthorizationControllerPresentationContextProviding {
  func presentationAnchor(
    for controller: ASAuthorizationController
  ) -> ASPresentationAnchor {
    NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? NSWindow()
  }
}
