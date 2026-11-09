import Foundation
import SpeakCore
import XCTest

@testable import SpeakApp

/// Sign in with Apple's web flow for direct-download Mac builds (issue #648).
final class AppleWebSignInTests: XCTestCase {
    private func query(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    func testAuthorizationURLUsesTheServicesIDReturnURLAndFormPost() {
        let url = AppleWebSignIn.authorizationURL(state: "state-123", hashedNonce: "hashed")
        XCTAssertEqual(url.host, "appleid.apple.com")
        XCTAssertEqual(url.path, "/auth/authorize")
        let items = self.query(url)
        XCTAssertEqual(items["client_id"], "com.justspeaktoit.mac.signin")
        XCTAssertEqual(items["redirect_uri"], "https://api.justspeaktoit.com/v1/auth/apple/callback")
        XCTAssertEqual(items["response_type"], "code id_token")
        XCTAssertEqual(items["response_mode"], "form_post")
        XCTAssertEqual(items["state"], "state-123")
        XCTAssertEqual(items["nonce"], "hashed")
    }

    func testCallbackYieldsTheTokenOnlyForThisAttempt() throws {
        let callback = URL(string: "justspeaktoit-auth://apple-callback?state=s1&id_token=a.b.c")!
        XCTAssertEqual(try AppleWebSignIn.identityToken(from: callback, expectedState: "s1"), "a.b.c")
        XCTAssertThrowsError(try AppleWebSignIn.identityToken(from: callback, expectedState: "s2")) {
            XCTAssertEqual($0 as? AppleWebSignIn.CallbackError, .stateMismatch)
        }
    }

    func testCallbackRefusesOtherSchemesErrorsAndMissingTokens() {
        let cases: [(String, AppleWebSignIn.CallbackError)] = [
            ("https://apple-callback?state=s1&id_token=a.b.c", .failed),
            ("justspeaktoit-auth://elsewhere?state=s1&id_token=a.b.c", .failed),
            ("justspeaktoit-auth://apple-callback?state=s1&error=cancelled", .cancelled),
            ("justspeaktoit-auth://apple-callback?state=s1&error=failed", .failed),
            ("justspeaktoit-auth://apple-callback?state=s1", .failed),
            ("justspeaktoit-auth://apple-callback?id_token=a.b.c", .stateMismatch)
        ]
        for (raw, expected) in cases {
            XCTAssertThrowsError(try AppleWebSignIn.identityToken(from: URL(string: raw)!, expectedState: "s1"), raw) {
                XCTAssertEqual($0 as? AppleWebSignIn.CallbackError, expected, raw)
            }
        }
    }

    @MainActor
    func testWebSignInExchangesTheRelayedTokenWithTheMatchingRawNonce() async throws {
        let client = RecordingSignInClient()
        let manager = Self.makeManager(client: client)
        manager.usesWebSignIn = true
        var requested: URL?
        manager.webAuthenticator = { url, scheme in
            XCTAssertEqual(scheme, "justspeaktoit-auth")
            requested = url
            let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "state" }?.value ?? ""
            return URL(string: "justspeaktoit-auth://apple-callback?state=\(state)&id_token=header.claims.sig")!
        }

        await manager.signIn()

        let attempt = try XCTUnwrap(client.attempts.first)
        XCTAssertEqual(client.attempts.count, 1)
        XCTAssertEqual(attempt.identityToken, "header.claims.sig")
        let url = try XCTUnwrap(requested)
        XCTAssertEqual(self.query(url)["nonce"], PaidAccessManager.sha256Hex(attempt.rawNonce))
        XCTAssertNotEqual(self.query(url)["state"], attempt.rawNonce, "state and nonce are independent")
        XCTAssertFalse(manager.isBusy)
    }

    @MainActor
    func testForgedCallbackStateNeverReachesTheServer() async {
        let client = RecordingSignInClient()
        let manager = Self.makeManager(client: client)
        manager.usesWebSignIn = true
        manager.webAuthenticator = { _, _ in
            URL(string: "justspeaktoit-auth://apple-callback?state=forged-state-value&id_token=a.b.c")!
        }

        await manager.signIn()

        XCTAssertTrue(client.attempts.isEmpty)
        XCTAssertEqual(manager.lastError, "Apple did not return an identity token.")
        XCTAssertFalse(manager.isSignedIn)
    }

    @MainActor
    func testCancelledWebSignInShowsNoError() async {
        let client = RecordingSignInClient()
        let manager = Self.makeManager(client: client)
        manager.usesWebSignIn = true
        manager.webAuthenticator = { _, _ in throw AppleWebSignIn.CallbackError.cancelled }

        await manager.signIn()

        XCTAssertTrue(client.attempts.isEmpty)
        XCTAssertNil(manager.lastError)
        XCTAssertFalse(manager.isBusy)
    }

    @MainActor
    private static func makeManager(client: RecordingSignInClient) -> PaidAccessManager {
        let defaults = UserDefaults(suiteName: "com.speakapp.tests.\(UUID().uuidString)")!
        return PaidAccessManager(
            client: client, sessionStore: MemorySessionStore(), settings: AppSettings(defaults: defaults)
        )
    }
}

private actor MemorySessionStore: PaidAccessSessionStoring {
    private var session: PaidAccessSession?
    func loadSession() async -> PaidAccessSession? { self.session }
    func saveSession(_ session: PaidAccessSession) async throws { self.session = session }
    func clearSession() async { self.session = nil }
}

/// Records sign-in exchanges and refuses them, so no session is ever created.
private final class RecordingSignInClient: PaidAccessClienting, @unchecked Sendable {
    struct Attempt { let identityToken: String; let rawNonce: String }
    private let lock = NSLock()
    private var recorded: [Attempt] = []
    var attempts: [Attempt] { self.lock.withLock { self.recorded } }

    func signInWithApple(
        identityToken: String, rawNonce: String, deviceLabel: String?
    ) async throws -> PaidAccessSession {
        self.lock.withLock { self.recorded.append(Attempt(identityToken: identityToken, rawNonce: rawNonce)) }
        throw PaidAccessError.invalidResponse
    }

    func refresh(session: PaidAccessSession) async throws -> PaidAccessSession {
        throw PaidAccessError.invalidResponse
    }
    func signOut(session: PaidAccessSession) async {}
    func entitlement(session: PaidAccessSession) async throws -> PaidAccessState {
        throw PaidAccessError.invalidResponse
    }
    func createCheckoutURL(session: PaidAccessSession) async throws -> URL { throw PaidAccessError.invalidResponse }
    func createBillingPortalURL(session: PaidAccessSession) async throws -> URL {
        throw PaidAccessError.invalidResponse
    }
    func syncStoreKitTransaction(
        session: PaidAccessSession, signedTransaction: String, signedRenewalInfo: String?
    ) async throws -> PaidEntitlement { throw PaidAccessError.invalidResponse }
    func transcribe(
        session: PaidAccessSession, audio: Data, contentType: String, language: String?, idempotencyKey: String
    ) async throws -> String { throw PaidAccessError.invalidResponse }
    func postProcess(
        session: PaidAccessSession, text: String, systemPrompt: String?, temperature: Double, idempotencyKey: String
    ) async throws -> String { throw PaidAccessError.invalidResponse }
    func liveTranscriptionRequest(session: PaidAccessSession, language: String?, sampleRate: Int) throws -> URLRequest {
        throw PaidAccessError.invalidResponse
    }
}
