// swiftlint:disable file_length
import AVFoundation
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
            .invalidResponse,
            // Already paid for once. Re-running it through the user's own key
            // would spend their money to cover our lost response.
            .alreadyProcessed
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
            .invalidResponse, .network("timeout"), .alreadyProcessed
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
        // 409 shared with `conflict`, so the body's code is what distinguishes
        // "already finished, do not retry" from "still running, try later".
        XCTAssertEqual(mapped("already_processed", status: 409), .alreadyProcessed)
        XCTAssertEqual(mapped("conflict", status: 409), .serviceUnavailable(statusCode: 409))
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

    func testIdempotencyKey_isStableAcrossRetriesOfTheSameAttempt() {
        // A timeout followed by a retry of the same attempt must present the
        // same key, or the Worker meters and bills one dictation twice.
        let attempt = UUID().uuidString
        let first = PaidAccessHTTPClient.idempotencyKey(
            operation: .batchTranscription,
            attemptID: attempt,
            parameters: ["model", "audio/wav", "en"],
            payload: Data("audio".utf8)
        )
        let retry = PaidAccessHTTPClient.idempotencyKey(
            operation: .batchTranscription,
            attemptID: attempt,
            parameters: ["model", "audio/wav", "en"],
            payload: Data("audio".utf8)
        )
        XCTAssertEqual(first, retry)
    }

    func testIdempotencyKey_differsWhenTheSameWordsAreDictatedAgain() {
        // The load-bearing case. Saying "delete the file" twice in a day is
        // ordinary use, not a duplicate: keying on content alone refused the
        // second one, and after the claim expired it paid the vendor and then
        // lost the result to the permanent ledger uniqueness.
        let identicalContent: (String) -> String = { attempt in
            PaidAccessHTTPClient.idempotencyKey(
                operation: .postProcessing,
                attemptID: attempt,
                parameters: ["model", "prompt", "0.2"],
                payload: Data("delete the file".utf8)
            )
        }
        XCTAssertNotEqual(identicalContent(UUID().uuidString), identicalContent(UUID().uuidString))
    }

    func testIdempotencyKey_differsForDifferentRequests() {
        let attempt = UUID().uuidString
        let base = PaidAccessHTTPClient.idempotencyKey(
            operation: .postProcessing,
            attemptID: attempt,
            parameters: ["model", "prompt", "0.2"],
            payload: Data("hello".utf8)
        )
        let otherPayload = PaidAccessHTTPClient.idempotencyKey(
            operation: .postProcessing,
            attemptID: attempt,
            parameters: ["model", "prompt", "0.2"],
            payload: Data("goodbye".utf8)
        )
        let otherParameters = PaidAccessHTTPClient.idempotencyKey(
            operation: .postProcessing,
            attemptID: attempt,
            parameters: ["model", "prompt", "0.9"],
            payload: Data("hello".utf8)
        )
        let otherOperation = PaidAccessHTTPClient.idempotencyKey(
            operation: .batchTranscription,
            attemptID: attempt,
            parameters: ["model", "prompt", "0.2"],
            payload: Data("hello".utf8)
        )
        XCTAssertEqual(Set([base, otherPayload, otherParameters, otherOperation]).count, 4)
    }

    func testIdempotencyKey_matchesTheShapeTheWorkerAccepts() {
        let key = PaidAccessHTTPClient.idempotencyKey(
            operation: .postProcessing,
            attemptID: UUID().uuidString,
            payload: Data()
        )
        XCTAssertTrue((16...128).contains(key.count))
        XCTAssertTrue(key.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil)
    }
}

/// An entitlement and the routing policy it was issued with are only meaningful
/// together: an active entitlement with an empty policy routes nothing, so the
/// app would believe it was subscribed and have nowhere to send the request.
final class PaidAccessStateCommitTests: XCTestCase {
    private func decodeState(_ json: String) throws -> PaidAccessState {
        try JSONDecoder().decode(EntitlementResponse.self, from: Data(json.utf8)).state
    }

    func testEntitlementAndPolicy_comeFromOneDecodeOfOnePayload() throws {
        // Both halves arrive in a single response and are turned into a single
        // value, so there is no interval in which one is published without the
        // other. Two requests, committed separately, is what this replaced.
        let state = try self.decodeState(
            """
            {
              "status": "active",
              "plan_id": "paid",
              "source": "stripe",
              "current_period_end": 1893456000,
              "cancel_at_period_end": false,
              "paid_routing_available": true,
              "policy": {
                "routes": [
                  {
                    "operation": "post_processing",
                    "model": "openai/gpt-5-mini",
                    "provider": "openrouter"
                  }
                ]
              }
            }
            """
        )

        XCTAssertEqual(state.entitlement.status, .active)
        XCTAssertTrue(state.entitlement.paidRoutingAvailable)
        // The policy must be populated in the same value, not left to a second
        // call that might fail and strand an entitled user with no route.
        XCTAssertFalse(state.policy.routes.isEmpty)
        XCTAssertEqual(state.policy.routes.first?.operation, .postProcessing)
    }

    func testMissingPolicy_yieldsAnEntitlementThatRoutesNothing() throws {
        // A response with no policy still publishes the entitlement, because the
        // subscription state is worth showing; the empty policy is what makes
        // the router fall the work back to the user's own configuration rather
        // than sending it somewhere it was never told about.
        let state = try self.decodeState(
            """
            {
              "status": "active",
              "plan_id": "paid",
              "source": "stripe",
              "cancel_at_period_end": false,
              "paid_routing_available": true
            }
            """
        )

        XCTAssertEqual(state.entitlement.status, .active)
        XCTAssertEqual(state.policy, .unknown)
        XCTAssertTrue(state.policy.routes.isEmpty)
    }
}

/// The paid batch endpoint accepts WAV and nothing else, while the app records
/// AAC in an `.m4a`. Without conversion every paid transcription silently falls
/// back to the user's own key, so the subscription buys nothing.
final class PaidAudioPayloadTests: XCTestCase {
    private var scratch = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        try super.setUpWithError()
        self.scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: self.scratch,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: self.scratch)
        try super.tearDownWithError()
    }

    /// Writes `seconds` of silence in whichever container `url`'s settings imply.
    private func writeAudio(
        to url: URL,
        settings: [String: Any],
        sampleRate: Double,
        seconds: Double
    ) throws {
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let frames = AVAudioFrameCount(sampleRate * seconds)
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: frames
            )
        else {
            XCTFail("Could not allocate a buffer to write the fixture")
            return
        }
        buffer.frameLength = frames
        try file.write(from: buffer)
    }

    private func pcmSettings(sampleRate: Double) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
    }

    func testWavData_convertsANonWavRecordingIntoAReadableWav() throws {
        // A CAF stands in for the recorded `.m4a`: it is a different container
        // that AVFoundation reads, which is the property under test. Encoding
        // AAC in a unit test would depend on a hardware encoder.
        let source = self.scratch.appendingPathComponent("recording.caf")
        try self.writeAudio(
            to: source,
            settings: self.pcmSettings(sampleRate: 44_100),
            sampleRate: 44_100,
            seconds: 0.5
        )

        let data = try PaidAudioPayload.wavData(contentsOf: source)

        // The server reads the duration out of this header to bill the request,
        // so it has to be a real RIFF/WAVE header, not merely non-empty bytes.
        XCTAssertGreaterThan(data.count, 44)
        XCTAssertEqual(String(bytes: data.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(bytes: data.dropFirst(8).prefix(4), encoding: .ascii), "WAVE")

        // And it must still be audio of the same length once decoded back.
        let roundTrip = self.scratch.appendingPathComponent("converted.wav")
        try data.write(to: roundTrip)
        let decoded = try AVAudioFile(forReading: roundTrip)
        XCTAssertEqual(decoded.fileFormat.sampleRate, 44_100)
        let duration = Double(decoded.length) / decoded.fileFormat.sampleRate
        XCTAssertEqual(duration, 0.5, accuracy: 0.05)

        // 16-bit, not the 32-bit float AVAudioFile hands back: it is what the
        // transcription providers expect and it halves the upload.
        let bitDepth = decoded.fileFormat.streamDescription.pointee.mBitsPerChannel
        XCTAssertEqual(bitDepth, 16)
    }

    func testWavData_passesAnExistingWavThroughUnchanged() throws {
        let source = self.scratch.appendingPathComponent("already.wav")
        try self.writeAudio(
            to: source,
            settings: self.pcmSettings(sampleRate: 16_000),
            sampleRate: 16_000,
            seconds: 0.25
        )
        let original = try Data(contentsOf: source)

        XCTAssertEqual(try PaidAudioPayload.wavData(contentsOf: source), original)
    }

    func testWavData_reportsUnreadableAudioRatherThanReturningRubbish() throws {
        let source = self.scratch.appendingPathComponent("notaudio.m4a")
        try Data("this is not audio".utf8).write(to: source)

        XCTAssertThrowsError(try PaidAudioPayload.wavData(contentsOf: source)) { error in
            XCTAssertEqual(error as? PaidAudioPayloadError, .unreadableAudio)
        }
    }
}
