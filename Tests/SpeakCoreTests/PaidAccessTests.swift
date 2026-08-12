// swiftlint:disable file_length
import XCTest

@testable import SpeakCore

/// Behavioural cover for the Paid Access domain: entitlement state, routing
/// decisions, billing-channel selection and the hidden-model UI policy.
///
/// The load-bearing assertions are the negative ones — an unsubscribed or
/// lapsed user must keep exactly the behaviour they had before paid access
/// existed.
final class PaidAccessEntitlementTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func entitlement(
        status: PaidEntitlementStatus,
        periodEnd: TimeInterval? = 3_600,
        paidRoutingAvailable: Bool = true
    ) -> PaidEntitlement {
        PaidEntitlement(
            status: status,
            planID: "paid",
            provider: .stripe,
            currentPeriodEnd: periodEnd.map { self.now.addingTimeInterval($0) },
            cancelAtPeriodEnd: false,
            paidRoutingAvailable: paidRoutingAvailable,
            usage: nil
        )
    }

    // MARK: - Entitlement state transitions

    func testActiveEntitlement_withinPeriod_grantsAccess() {
        XCTAssertTrue(self.entitlement(status: .active).isActive(asOf: self.now))
        XCTAssertTrue(self.entitlement(status: .trialing).isActive(asOf: self.now))
        XCTAssertTrue(self.entitlement(status: .grace).isActive(asOf: self.now))
    }

    func testActiveEntitlement_afterPeriodEnd_deniesAccess() {
        let lapsed = self.entitlement(status: .active, periodEnd: -1)
        XCTAssertFalse(lapsed.isActive(asOf: self.now))
        XCTAssertFalse(lapsed.allowsPaidRouting(asOf: self.now))
    }

    func testNonGrantingStatuses_denyAccessEvenInsideAPaidPeriod() {
        for status in [PaidEntitlementStatus.none, .pastDue, .revoked, .expired] {
            XCTAssertFalse(
                self.entitlement(status: status).isActive(asOf: self.now),
                "\(status.rawValue) must not grant access"
            )
        }
    }

    func testEntitlementWithNoPeriodEnd_remainsActive() {
        XCTAssertTrue(self.entitlement(status: .active, periodEnd: nil).isActive(asOf: self.now))
    }

    func testUnentitled_isTheSafeDefault() {
        XCTAssertEqual(PaidEntitlement.unentitled.status, .none)
        XCTAssertFalse(PaidEntitlement.unentitled.isActive(asOf: self.now))
        XCTAssertFalse(PaidEntitlement.unentitled.allowsPaidRouting(asOf: self.now))
    }

    func testKillSwitch_deniesPaidRoutingWhileLeavingTheSubscriptionActive() {
        let killed = self.entitlement(status: .active, paidRoutingAvailable: false)
        XCTAssertTrue(killed.isActive(asOf: self.now), "The subscription itself stays valid")
        XCTAssertFalse(killed.allowsPaidRouting(asOf: self.now), "Routing is switched off")
    }

    func testEveryStatus_hasUserFacingCopy() {
        for status in PaidEntitlementStatus.allCases {
            XCTAssertFalse(status.displayName.isEmpty)
        }
    }

    // MARK: - Usage

    func testUsageSnapshot_reportsFractionUsed() {
        let usage = PaidUsageSnapshot(
            period: "2026-08",
            audioSecondsUsed: 45_000,
            audioSecondsLimit: 180_000,
            tokensUsed: 0,
            tokensLimit: 20_000_000,
            activeSessions: 0,
            maxConcurrentSessions: 2
        )
        XCTAssertEqual(usage.audioFractionUsed, 0.25, accuracy: 0.0001)
    }

    func testUsageSnapshot_clampsAndAvoidsDivideByZero() {
        let overspent = PaidUsageSnapshot(
            period: "2026-08",
            audioSecondsUsed: 200,
            audioSecondsLimit: 100,
            tokensUsed: 0,
            tokensLimit: 0,
            activeSessions: 0,
            maxConcurrentSessions: 1
        )
        XCTAssertEqual(overspent.audioFractionUsed, 1)

        let unlimited = PaidUsageSnapshot(
            period: "2026-08",
            audioSecondsUsed: 10,
            audioSecondsLimit: 0,
            tokensUsed: 0,
            tokensLimit: 0,
            activeSessions: 0,
            maxConcurrentSessions: 1
        )
        XCTAssertEqual(unlimited.audioFractionUsed, 0)
    }

    // MARK: - Sessions

    func testSession_needsRefreshInsideTheExpiryMargin() {
        let session = PaidAccessSession(
            accessToken: "access",
            accessTokenExpiresAt: self.now.addingTimeInterval(30),
            refreshToken: "refresh",
            refreshTokenExpiresAt: self.now.addingTimeInterval(86_400),
            userID: "user-1"
        )
        XCTAssertTrue(session.needsRefresh(asOf: self.now, margin: 60))
        XCTAssertFalse(session.needsRefresh(asOf: self.now, margin: 10))
        XCTAssertTrue(session.isRefreshable(asOf: self.now))
    }

    func testSession_withExpiredRefreshToken_isNotRefreshable() {
        let session = PaidAccessSession(
            accessToken: "access",
            accessTokenExpiresAt: self.now.addingTimeInterval(-10),
            refreshToken: "refresh",
            refreshTokenExpiresAt: self.now.addingTimeInterval(-1),
            userID: "user-1"
        )
        XCTAssertFalse(session.isRefreshable(asOf: self.now))
    }
}

final class PaidAccessRoutingTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private let policy = PaidRoutingPolicy(
        version: "2026-08-12",
        routes: [
            PaidRoute(
                operation: .liveTranscription,
                provider: "deepgram",
                model: "deepgram/nova-3-streaming",
                displayName: "Deepgram Nova-3 (Streaming)"
            ),
            PaidRoute(
                operation: .batchTranscription,
                provider: "openrouter",
                model: "google/gemini-2.0-flash-001",
                displayName: "Gemini 2.0 Flash"
            ),
            PaidRoute(
                operation: .postProcessing,
                provider: "openrouter",
                model: "openai/gpt-5-mini",
                displayName: "GPT-5 Mini"
            )
        ]
    )

    private func entitled(_ status: PaidEntitlementStatus = .active) -> PaidEntitlement {
        PaidEntitlement(
            status: status,
            planID: "paid",
            provider: .storeKit,
            currentPeriodEnd: self.now.addingTimeInterval(3_600),
            cancelAtPeriodEnd: false,
            paidRoutingAvailable: true,
            usage: nil
        )
    }

    private func router(
        entitlement: PaidEntitlement,
        preferred: Bool
    ) -> PaidAccessRouter {
        PaidAccessRouter(
            entitlement: entitlement,
            policy: self.policy,
            isPaidRoutingPreferred: preferred
        )
    }

    // MARK: - Paid routing

    func testEntitledUser_withPaidRoutingOn_usesTheServerChosenModel() throws {
        let decision = try self.router(entitlement: self.entitled(), preferred: true)
            .decide(
                for: .postProcessing,
                configuredModel: "anthropic/claude-haiku-4.5",
                now: self.now
            )
        XCTAssertTrue(decision.usesPaidService)
        // The user's own selection is deliberately ignored on the paid path.
        XCTAssertEqual(decision.effectiveModelID, "openai/gpt-5-mini")
    }

    func testEveryPaidOperation_resolvesToARoute() throws {
        let router = self.router(entitlement: self.entitled(), preferred: true)
        for operation in PaidOperation.allCases {
            let decision = try router.decide(
                for: operation,
                configuredModel: "openai/gpt-5-mini",
                now: self.now
            )
            XCTAssertTrue(decision.usesPaidService, "\(operation.rawValue) should route to the service")
        }
    }

    // MARK: - Bring-your-own-key remains the default

    func testUnentitledUser_keepsTheirOwnKeyAndModel() throws {
        let decision = try self.router(entitlement: .unentitled, preferred: true)
            .decide(for: .postProcessing, configuredModel: "openai/gpt-5-mini", now: self.now)
        XCTAssertFalse(decision.usesPaidService)
        XCTAssertEqual(decision, .bringYourOwnKey(model: "openai/gpt-5-mini"))
    }

    func testEntitledUser_withPaidRoutingOff_keepsTheirOwnKeyAndModel() throws {
        let decision = try self.router(entitlement: self.entitled(), preferred: false)
            .decide(for: .batchTranscription, configuredModel: "openai/whisper-1", now: self.now)
        XCTAssertEqual(decision, .bringYourOwnKey(model: "openai/whisper-1"))
    }

    func testLapsedSubscription_fallsBackToTheUsersOwnConfiguration() throws {
        let lapsed = PaidEntitlement(
            status: .active,
            planID: "paid",
            provider: .stripe,
            currentPeriodEnd: self.now.addingTimeInterval(-1),
            cancelAtPeriodEnd: true,
            paidRoutingAvailable: true,
            usage: nil
        )
        let decision = try self.router(entitlement: lapsed, preferred: true)
            .decide(for: .postProcessing, configuredModel: "openai/gpt-5-mini", now: self.now)
        XCTAssertEqual(decision, .bringYourOwnKey(model: "openai/gpt-5-mini"))
    }

    func testLocalModelSelection_staysLocalForAnUnentitledUser() throws {
        let decision = try self.router(entitlement: .unentitled, preferred: true)
            .decide(
                for: .postProcessing,
                configuredModel: "local/post-processing/rules",
                now: self.now
            )
        XCTAssertEqual(decision, .localModel(model: "local/post-processing/rules"))
    }

    func testAppleOnDeviceSelection_staysLocalForAnUnentitledUser() throws {
        let decision = try self.router(entitlement: .unentitled, preferred: true)
            .decide(
                for: .liveTranscription,
                configuredModel: AppleLocalModels.preferredSpeechModelID,
                now: self.now
            )
        XCTAssertEqual(decision, .localModel(model: AppleLocalModels.preferredSpeechModelID))
    }

    func testOnDeviceSelection_staysLocalForAnEntitledSubscriber() throws {
        // Paid access is a convenience over remote keys, never an opt-in to
        // uploading audio the user asked to keep on the device.
        let router = self.router(entitlement: self.entitled(), preferred: true)

        let speech = try router.decide(
            for: .liveTranscription,
            configuredModel: AppleLocalModels.preferredSpeechModelID,
            now: self.now
        )
        XCTAssertEqual(speech, .localModel(model: AppleLocalModels.preferredSpeechModelID))

        let cleanup = try router.decide(
            for: .postProcessing,
            configuredModel: "local/post-processing/rules",
            now: self.now
        )
        XCTAssertEqual(cleanup, .localModel(model: "local/post-processing/rules"))
    }

    func testQuotaExceeded_permitsSilentFallbackToTheUsersOwnKey() {
        // The message tells the user their own keys still work, so the current
        // request has to complete rather than being lost.
        XCTAssertTrue(PaidAccessError.quotaExceeded.permitsSilentFallback)
    }

    // MARK: - Unsupported operations fail loudly

    func testOperationWithNoPublishedRoute_throwsRatherThanSilentlyFallingBack() {
        let emptyPolicy = PaidRoutingPolicy(version: "empty", routes: [])
        let router = PaidAccessRouter(
            entitlement: self.entitled(),
            policy: emptyPolicy,
            isPaidRoutingPreferred: true
        )
        XCTAssertThrowsError(
            try router.decide(
                for: .liveTranscription,
                configuredModel: "deepgram/nova-3-streaming",
                now: self.now
            )
        ) { error in
            XCTAssertEqual(error as? PaidAccessError, .unsupportedOperation(.liveTranscription))
        }
    }

    func testPolicyLookup_returnsNilForAMissingOperation() {
        let partial = PaidRoutingPolicy(version: "partial", routes: [])
        XCTAssertNil(partial.route(for: .postProcessing))
        XCTAssertNil(PaidRoutingPolicy.unknown.route(for: .batchTranscription))
    }
}

final class PaidAccessChannelPolicyTests: XCTestCase {

    // MARK: - StoreKit / Stripe channel selection

    func testDirectDownload_usesStripeCheckout() {
        XCTAssertEqual(DistributionChannel.direct.paidBillingChannel, .stripeCheckout)
        XCTAssertEqual(DistributionChannel.direct.paidBillingChannel.provider, .stripe)
        XCTAssertTrue(DistributionChannel.direct.paidBillingChannel.opensExternalBrowser)
    }

    func testAppStoreBuilds_useStoreKit() {
        XCTAssertEqual(DistributionChannel.appStore.paidBillingChannel, .storeKit)
        XCTAssertEqual(DistributionChannel.appStore.paidBillingChannel.provider, .storeKit)
        XCTAssertFalse(
            DistributionChannel.appStore.paidBillingChannel.opensExternalBrowser,
            "App Store purchases must stay in-app"
        )
    }

    func testEveryChannel_hasPurchaseAndManageCopy() {
        for channel in [PaidBillingChannel.stripeCheckout, .storeKit] {
            XCTAssertFalse(channel.purchaseActionTitle.isEmpty)
            XCTAssertFalse(channel.manageActionTitle.isEmpty)
        }
    }
}

final class SimpleModelChoicesPolicyTests: XCTestCase {

    // MARK: - Hidden-model UI policy

    func testModelSelection_isHiddenOnlyWhenEnabledAndPaidRoutingIsAvailable() {
        XCTAssertTrue(
            SimpleModelChoicesPolicy(isEnabled: true, hasPaidRouting: true).hidesModelSelection
        )
        XCTAssertFalse(
            SimpleModelChoicesPolicy(isEnabled: true, hasPaidRouting: false).hidesModelSelection,
            "A lapsed subscriber must keep their model pickers"
        )
        XCTAssertFalse(
            SimpleModelChoicesPolicy(isEnabled: false, hasPaidRouting: true).hidesModelSelection
        )
        XCTAssertFalse(
            SimpleModelChoicesPolicy(isEnabled: false, hasPaidRouting: false).hidesModelSelection
        )
    }

    func testExplanation_alwaysMentionsThatLocalAndOwnKeysRemainAvailable() {
        let hidden = SimpleModelChoicesPolicy(isEnabled: true, hasPaidRouting: true).explanation
        XCTAssertTrue(hidden.lowercased().contains("api keys"))
        XCTAssertTrue(hidden.lowercased().contains("on-device"))
    }

    func testExplanation_isPresentInEveryState() {
        for isEnabled in [true, false] {
            for hasPaidRouting in [true, false] {
                let policy = SimpleModelChoicesPolicy(
                    isEnabled: isEnabled,
                    hasPaidRouting: hasPaidRouting
                )
                XCTAssertFalse(policy.explanation.isEmpty)
            }
        }
    }
}

final class PaidAccessErrorTests: XCTestCase {

    // MARK: - Failure handling

    func testTransientFailures_permitSilentFallbackToTheUsersOwnSetup() {
        let fallbackable: [PaidAccessError] = [
            .notSignedIn,
            .entitlementRequired,
            .paidRoutingDisabled,
            .serviceUnavailable(statusCode: 503),
            .network("offline"),
            // Running out of included usage is not a failure of the user's own
            // setup, and the message promises their own keys still work.
            .quotaExceeded
        ]
        for error in fallbackable {
            XCTAssertTrue(error.permitsSilentFallback, "\(error) should fall back quietly")
        }
    }

    func testUserActionableFailures_areSurfacedRatherThanHidden() {
        let surfaced: [PaidAccessError] = [
            .tooManySessions,
            .unsupportedOperation(.liveTranscription),
            .invalidResponse
        ]
        for error in surfaced {
            XCTAssertFalse(error.permitsSilentFallback, "\(error) should be shown to the user")
        }
    }

    func testEveryError_hasADescriptionAndNeverLeaksCredentials() {
        let errors: [PaidAccessError] = [
            .notSignedIn, .entitlementRequired, .quotaExceeded, .tooManySessions,
            .unsupportedOperation(.postProcessing), .paidRoutingDisabled,
            .billingChannelUnavailable("nope"), .serviceUnavailable(statusCode: 500),
            .invalidResponse, .network("timeout")
        ]
        for error in errors {
            let description = error.errorDescription ?? ""
            XCTAssertFalse(description.isEmpty)
            XCTAssertFalse(description.lowercased().contains("bearer"))
        }
    }

    func testAvailabilityErrors_tellTheUserTheirOwnKeysStillWork() {
        for error in [PaidAccessError.entitlementRequired, .quotaExceeded, .paidRoutingDisabled] {
            let description = (error.errorDescription ?? "").lowercased()
            XCTAssertTrue(
                description.contains("api keys") && description.contains("local models"),
                "\(error) must point the user at the free alternatives"
            )
        }
    }

    // MARK: - Server error mapping

    func testServerErrorCodes_mapOntoDomainErrors() {
        func mapped(_ code: String, status: Int = 400) -> PaidAccessError {
            let body = Data(#"{"error":{"code":"\#(code)","message":"x"}}"#.utf8)
            return PaidAccessHTTPClient.error(forStatus: status, body: body)
        }

        XCTAssertEqual(mapped("entitlement_required", status: 402), .entitlementRequired)
        XCTAssertEqual(mapped("quota_exceeded", status: 429), .quotaExceeded)
        XCTAssertEqual(mapped("too_many_sessions", status: 429), .tooManySessions)
        XCTAssertEqual(mapped("paid_routing_disabled", status: 503), .paidRoutingDisabled)
        XCTAssertEqual(mapped("unauthorized", status: 401), .notSignedIn)
    }

    func testUnrecognisedErrorBody_doesNotBecomeASuccess() {
        let error = PaidAccessHTTPClient.error(forStatus: 500, body: Data("not json".utf8))
        XCTAssertEqual(error, .serviceUnavailable(statusCode: 500))
    }

    func testUnauthenticatedResponseWithNoBody_mapsToNotSignedIn() {
        XCTAssertEqual(
            PaidAccessHTTPClient.error(forStatus: 401, body: Data()),
            .notSignedIn
        )
    }
}

final class PaidAccessClientRequestTests: XCTestCase {

    private let session = PaidAccessSession(
        accessToken: "test-access-token",
        accessTokenExpiresAt: Date(timeIntervalSince1970: 1_800_003_600),
        refreshToken: "test-refresh-token",
        refreshTokenExpiresAt: Date(timeIntervalSince1970: 1_802_592_000),
        userID: "user-1"
    )

    func testLiveTranscriptionRequest_carriesOnlyTheUsersOwnSessionToken() throws {
        let client = PaidAccessHTTPClient(baseURL: URL(string: "https://api.example.com")!)
        let request = try client.liveTranscriptionRequest(
            session: self.session,
            language: "en",
            sampleRate: 16_000
        )

        let url = try XCTUnwrap(request.url)
        // `URLSessionWebSocketTask` only accepts ws/wss.
        XCTAssertEqual(url.scheme, "wss")
        XCTAssertEqual(url.path, "/v1/paid/transcribe/live")
        XCTAssertTrue(url.query?.contains("sample_rate=16000") == true)
        XCTAssertTrue(url.query?.contains("language=en") == true)
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer test-access-token"
        )
        // The socket terminates at our Worker, so no vendor key is present.
        XCTAssertNil(request.value(forHTTPHeaderField: "Token"))
    }

    func testEveryRequest_carriesACorrelationIdentifier() throws {
        let client = PaidAccessHTTPClient(baseURL: URL(string: "https://api.example.com")!)
        let request = try client.liveTranscriptionRequest(
            session: self.session,
            language: nil,
            sampleRate: 48_000
        )
        let correlationID = try XCTUnwrap(request.value(forHTTPHeaderField: "X-Correlation-ID"))
        XCTAssertTrue(
            correlationID.range(of: "^[A-Za-z0-9_-]{8,64}$", options: .regularExpression) != nil,
            "Correlation ids must match the shape the Worker accepts"
        )
    }

    func testIdempotencyKeys_areUniqueAndWellFormed() {
        let first = PaidAccessHTTPClient.newIdempotencyKey()
        let second = PaidAccessHTTPClient.newIdempotencyKey()
        XCTAssertNotEqual(first, second)
        for key in [first, second] {
            XCTAssertTrue((16...128).contains(key.count))
            XCTAssertTrue(key.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil)
        }
    }
}
