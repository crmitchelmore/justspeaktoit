import Foundation
import SpeakCore
import XCTest

@testable import SpeakApp

/// A checkout or billing-portal failure belongs to the account that started it:
/// one that arrives after the user has signed out must not show on whatever
/// the manager presents next.
@MainActor
final class PaidAccessManagerCheckoutTests: XCTestCase {
    func testCheckoutFailure_afterSignOutReportsNothing() async throws {
        try XCTSkipUnless(
            DistributionChannel.current.paidBillingChannel == .stripeCheckout,
            "The test host must take the Stripe checkout path"
        )
        let client = GatedCheckoutClient()
        let manager = Self.makeManager(client: client)

        let purchase = Task { await manager.purchase() }
        await client.waitUntilCheckoutRequested()
        await manager.signOut()
        await client.failCheckout()
        await purchase.value

        XCTAssertNil(manager.lastError, "A left account's checkout failure must not be reported")
        XCTAssertFalse(manager.isBusy)
    }

    func testCheckoutFailure_forTheCurrentAccountIsReported() async throws {
        try XCTSkipUnless(
            DistributionChannel.current.paidBillingChannel == .stripeCheckout,
            "The test host must take the Stripe checkout path"
        )
        let client = GatedCheckoutClient()
        let manager = Self.makeManager(client: client)

        let purchase = Task { await manager.purchase() }
        await client.waitUntilCheckoutRequested()
        await client.failCheckout()
        await purchase.value

        XCTAssertEqual(manager.lastError, PaidAccessError.invalidResponse.errorDescription)
    }

    private static func makeManager(client: GatedCheckoutClient) -> PaidAccessManager {
        let defaults = UserDefaults(suiteName: "com.speakapp.tests.\(UUID().uuidString)")!
        let session = PaidAccessSession(
            accessToken: "access",
            accessTokenExpiresAt: Date().addingTimeInterval(3_600),
            refreshToken: "refresh",
            refreshTokenExpiresAt: Date().addingTimeInterval(86_400),
            userID: "user-1"
        )
        return PaidAccessManager(
            client: client,
            sessionStore: SeededSessionStore(session),
            settings: AppSettings(defaults: defaults)
        )
    }
}

private actor SeededSessionStore: PaidAccessSessionStoring {
    private var session: PaidAccessSession?
    init(_ session: PaidAccessSession?) { self.session = session }
    func loadSession() async -> PaidAccessSession? { self.session }
    func saveSession(_ session: PaidAccessSession) async throws { self.session = session }
    func clearSession() async { self.session = nil }
}

/// Holds `createCheckoutURL` open until the test fails it.
private final class GatedCheckoutClient: PaidAccessClienting, @unchecked Sendable {
    private let gate = CheckoutGate()

    func waitUntilCheckoutRequested() async { await self.gate.waitUntilRequested() }
    func failCheckout() async { await self.gate.release() }

    func createCheckoutURL(session: PaidAccessSession) async throws -> URL {
        await self.gate.hold()
        throw PaidAccessError.invalidResponse
    }

    func signInWithApple(
        identityToken: String, rawNonce: String, deviceLabel: String?
    ) async throws -> PaidAccessSession { throw PaidAccessError.invalidResponse }
    func refresh(session: PaidAccessSession) async throws -> PaidAccessSession {
        throw PaidAccessError.invalidResponse
    }
    func signOut(session: PaidAccessSession) async {}
    func entitlement(session: PaidAccessSession) async throws -> PaidAccessState {
        throw PaidAccessError.invalidResponse
    }
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

private actor CheckoutGate {
    private var requested = false
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private var holder: CheckedContinuation<Void, Never>?
    private var released = false

    func hold() async {
        self.requested = true
        self.requestWaiters.forEach { $0.resume() }
        self.requestWaiters.removeAll()
        guard !self.released else { return }
        await withCheckedContinuation { self.holder = $0 }
    }

    func waitUntilRequested() async {
        guard !self.requested else { return }
        await withCheckedContinuation { self.requestWaiters.append($0) }
    }

    func release() {
        self.released = true
        self.holder?.resume()
        self.holder = nil
    }
}
