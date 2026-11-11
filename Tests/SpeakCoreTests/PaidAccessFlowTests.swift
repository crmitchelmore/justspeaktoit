#if canImport(StoreKit)
import Foundation
import SpeakCore
import XCTest

@MainActor
final class PaidAccessFlowTests: XCTestCase {
    private let active = PaidEntitlement(
        status: .active, planID: "paid", provider: .storeKit, currentPeriodEnd: Date().addingTimeInterval(3_600),
        cancelAtPeriodEnd: false, paidRoutingAvailable: true, usage: nil
    )

    private func session(userID: String = "user-1") -> PaidAccessSession {
        PaidAccessSession(
            accessToken: "access", accessTokenExpiresAt: Date().addingTimeInterval(3_600),
            refreshToken: "refresh", refreshTokenExpiresAt: Date().addingTimeInterval(86_400), userID: userID
        )
    }

    func testRefresh_commitsEntitlementAndPolicyTogether() async {
        let client = FlowClient(entitlement: .success(PaidAccessState(entitlement: active, policy: .unknown)))
        let flow = PaidAccessFlow(client: client, sessionStore: FlowSessionStore(session()))
        var published: [PaidAccessFlowState] = []
        flow.onChange = { published.append($0) }

        await flow.refreshEntitlement()

        XCTAssertEqual(flow.state.entitlement, active)
        XCTAssertTrue(flow.state.isSignedIn)
        XCTAssertNil(flow.state.lastError)
        XCTAssertEqual(published.last, flow.state, "Every change reaches the platform")
    }

    func testRefresh_signedOutByTheServerClearsTheSession() async {
        let store = FlowSessionStore(session())
        let flow = PaidAccessFlow(client: FlowClient(entitlement: .failure(.notSignedIn)), sessionStore: store)

        await flow.refreshEntitlement()

        XCTAssertFalse(flow.state.isSignedIn)
        XCTAssertEqual(flow.state.entitlement, .unentitled)
        let stored = await store.loadSession()
        XCTAssertNil(stored)
    }

    func testRefresh_outageKeepsTheLastKnownEntitlement() async {
        let client = FlowClient(entitlement: .success(PaidAccessState(entitlement: active, policy: .unknown)))
        let flow = PaidAccessFlow(client: client, sessionStore: FlowSessionStore(session()))
        await flow.refreshEntitlement()

        client.entitlementResult = .failure(.network("offline"))
        await flow.refreshEntitlement()

        XCTAssertEqual(flow.state.entitlement, active)
        XCTAssertEqual(flow.state.lastError, PaidAccessError.network("offline").errorDescription)
    }

    func testSignIn_acceptsTheSessionAndRefreshes() async {
        let client = FlowClient(entitlement: .success(PaidAccessState(entitlement: active, policy: .unknown)))
        client.signInSession = session(userID: "new")
        let flow = PaidAccessFlow(client: client, sessionStore: FlowSessionStore(nil))
        var hashedNonce: String?

        await flow.signIn(
            deviceLabel: "Mac",
            identityToken: { hashedNonce = $0; return "token" },
            errorMessage: { _ in "failed" }
        )

        XCTAssertTrue(flow.state.isSignedIn)
        XCTAssertEqual(flow.state.entitlement, active)
        XCTAssertFalse(flow.state.isBusy)
        XCTAssertEqual(client.signIns.first?.identityToken, "token")
        XCTAssertEqual(hashedNonce, client.signIns.first.map { PaidAccessNonce.sha256Hex($0.rawNonce) })
    }

    func testSignIn_reportsThePlatformMessageAndEndsTheOperation() async {
        let flow = PaidAccessFlow(
            client: FlowClient(entitlement: .failure(.notSignedIn)),
            sessionStore: FlowSessionStore(nil)
        )

        await flow.signIn(
            deviceLabel: nil,
            identityToken: { _ in throw CancellationError() },
            errorMessage: { $0 is CancellationError ? nil : "failed" }
        )
        XCTAssertNil(flow.state.lastError, "A dismissed sheet is not an error")
        XCTAssertFalse(flow.state.isBusy)

        await flow.signIn(
            deviceLabel: nil,
            identityToken: { _ in throw PaidAccessError.invalidResponse },
            errorMessage: { $0 is CancellationError ? nil : "failed" }
        )
        XCTAssertEqual(flow.state.lastError, "failed")
        XCTAssertFalse(flow.state.isSignedIn)
    }

    func testSignedInOperation_reportsAMissingSessionAndEndsBusy() async {
        let flow = PaidAccessFlow(
            client: FlowClient(entitlement: .failure(.notSignedIn)),
            sessionStore: FlowSessionStore(nil)
        )
        var ran = false

        await flow.withSignedInOperation(clearingError: true) { _, _ in ran = true }

        XCTAssertFalse(ran)
        XCTAssertEqual(flow.state.lastError, PaidAccessError.notSignedIn.errorDescription)
        XCTAssertFalse(flow.state.isBusy)
    }

    func testOperation_onlyTheNewestEndsBusy() {
        let flow = PaidAccessFlow(
            client: FlowClient(entitlement: .failure(.notSignedIn)),
            sessionStore: FlowSessionStore(nil)
        )
        let first = flow.beginOperation(clearingError: false)
        let second = flow.beginOperation(clearingError: false)

        flow.endOperation(first)
        XCTAssertTrue(flow.state.isBusy, "A superseded operation must not clear the newer one's busy state")
        flow.endOperation(second)
        XCTAssertFalse(flow.state.isBusy)
    }

    func testSignOut_clearsLocallyThenRevokes() async {
        let client = FlowClient(entitlement: .success(PaidAccessState(entitlement: active, policy: .unknown)))
        let store = FlowSessionStore(session())
        let flow = PaidAccessFlow(client: client, sessionStore: store)
        await flow.refreshEntitlement()

        await flow.signOut()

        XCTAssertFalse(flow.state.isSignedIn)
        XCTAssertEqual(flow.state.entitlement, .unentitled)
        XCTAssertEqual(client.signOuts, 1)
        let stored = await store.loadSession()
        XCTAssertNil(stored)
    }

    func testNonce_isUniqueURLSafeAndHashesToHex() {
        let first = PaidAccessNonce.makeRaw()
        XCTAssertNotEqual(first, PaidAccessNonce.makeRaw())
        XCTAssertEqual(first.count, 43)
        XCTAssertNil(first.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")))
        XCTAssertEqual(
            PaidAccessNonce.sha256Hex("abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }
}

private actor FlowSessionStore: PaidAccessSessionStoring {
    private var session: PaidAccessSession?

    init(_ session: PaidAccessSession?) {
        self.session = session
    }

    func loadSession() async -> PaidAccessSession? { session }
    func saveSession(_ session: PaidAccessSession) async throws { self.session = session }
    func clearSession() async { session = nil }
}

private final class FlowClient: PaidAccessClienting, @unchecked Sendable {
    struct SignIn { let identityToken: String; let rawNonce: String }

    private let lock = NSLock()
    private var _entitlementResult: Result<PaidAccessState, PaidAccessError>
    private var _signInSession: PaidAccessSession?
    private var _signIns: [SignIn] = []
    private var _signOuts = 0

    init(entitlement: Result<PaidAccessState, PaidAccessError>) {
        _entitlementResult = entitlement
    }

    var entitlementResult: Result<PaidAccessState, PaidAccessError> {
        get { lock.withLock { _entitlementResult } }
        set { lock.withLock { _entitlementResult = newValue } }
    }
    var signInSession: PaidAccessSession? {
        get { lock.withLock { _signInSession } }
        set { lock.withLock { _signInSession = newValue } }
    }
    var signIns: [SignIn] { lock.withLock { _signIns } }
    var signOuts: Int { lock.withLock { _signOuts } }

    func signInWithApple(
        identityToken: String,
        rawNonce: String,
        deviceLabel: String?
    ) async throws -> PaidAccessSession {
        lock.withLock { _signIns.append(SignIn(identityToken: identityToken, rawNonce: rawNonce)) }
        guard let session = signInSession else { throw PaidAccessError.invalidResponse }
        return session
    }

    func refresh(session: PaidAccessSession) async throws -> PaidAccessSession { session }
    func signOut(session: PaidAccessSession) async { lock.withLock { _signOuts += 1 } }
    func entitlement(session: PaidAccessSession) async throws -> PaidAccessState { try entitlementResult.get() }
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
#endif
