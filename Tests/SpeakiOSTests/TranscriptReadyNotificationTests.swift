#if os(iOS)
import SpeakCore
import UserNotifications
import XCTest
@testable import SpeakiOSLib

@MainActor
final class TranscriptReadyNotificationTests: XCTestCase {
    func testEligibility_SuppressesEachFailedDeliveryBoundary() {
        let eligible = TranscriptReadyNotificationInput(historyID: UUID())
        XCTAssertTrue(eligible.isEligible, "Late pickup without insertion remains eligible")
        XCTAssertFalse(TranscriptReadyNotificationInput(historyID: nil).isEligible)
        for keyPath in [\TranscriptReadyNotificationInput.transcriptIsEmpty, \.failed, \.isForeground,
                        \.keyboardInserted, \.matchingResultActivity] {
            var input = eligible
            input[keyPath: keyPath] = true
            XCTAssertFalse(input.isEligible)
        }
    }

    func testDisabledAndDenied_NeverPromptFromScheduling() async {
        let fixture = NotificationFixture()
        fixture.enabled = false
        let coordinator = fixture.coordinator()
        coordinator.submit(.init(historyID: UUID()))
        await coordinator.waitUntilIdle()
        XCTAssertEqual(fixture.permissionRequests, 0)
        XCTAssertEqual(fixture.authorizationReads, 0)
        fixture.permissionGranted = false
        let allowed = await coordinator.setEnabledFromUser(true)
        XCTAssertFalse(allowed)
        XCTAssertFalse(fixture.enabled)
        XCTAssertEqual(fixture.permissionRequests, 1)
        XCTAssertTrue(fixture.enqueued.isEmpty)
    }

    func testSerialDuplicateCallbacksAndEnqueueFailure_ClaimBeforeEnqueueAndNeverRetry() async throws {
        let fixture = NotificationFixture()
        let first = UUID()
        let second = UUID()
        fixture.enqueueFails = true
        let coordinator = fixture.coordinator()
        coordinator.submit(.init(historyID: first))
        coordinator.submit(.init(historyID: first))
        coordinator.submit(.init(historyID: second))
        await coordinator.waitUntilIdle()
        XCTAssertEqual(fixture.enqueued, [first, second])
        XCTAssertEqual(fixture.claimed, [first, second])
        fixture.enqueueFails = false
        let restarted = fixture.coordinator()
        restarted.submit(.init(historyID: first))
        await restarted.waitUntilIdle()
        XCTAssertEqual(fixture.enqueued, [first, second], "Failed enqueue retains the durable attempt")
        XCTAssertEqual(fixture.permissionRequests, 0)
    }

    func testRevokedAuthorizationAndFailedClaim_EnqueueNothing() async {
        let fixture = NotificationFixture()
        let coordinator = fixture.coordinator()
        fixture.authorized = false
        coordinator.submit(.init(historyID: UUID()))
        await coordinator.waitUntilIdle()
        XCTAssertTrue(fixture.claimed.isEmpty)
        fixture.authorized = true
        fixture.claimFails = true
        coordinator.submit(.init(historyID: UUID()))
        await coordinator.waitUntilIdle()
        XCTAssertTrue(fixture.enqueued.isEmpty)
    }

    func testOptOutDuringAuthorization_SkipsClaimAndRemovesOnlyOwnedPending() async {
        let fixture = NotificationFixture()
        let entered = expectation(description: "Authorization read")
        let gate = NotificationGate(entered: entered)
        fixture.authorizationGate = gate
        let owned = TranscriptReadyNotificationRoute.requestIdentifier(for: UUID())
        fixture.pending = [owned, "unrelated.remote-history"]
        let coordinator = fixture.coordinator()
        coordinator.submit(.init(historyID: UUID()))
        await fulfillment(of: [entered], timeout: 2)
        _ = await coordinator.setEnabledFromUser(false)
        gate.release()
        await coordinator.waitUntilIdle()
        XCTAssertTrue(fixture.claimed.isEmpty)
        XCTAssertTrue(fixture.enqueued.isEmpty)
        XCTAssertEqual(fixture.pending, ["unrelated.remote-history"])
    }

    func testOldPermissionGrantAfterOptOut_CannotReenable() async {
        let fixture = NotificationFixture()
        fixture.enabled = false
        let entered = expectation(description: "Permission request")
        let gate = NotificationGate(entered: entered)
        fixture.permissionGate = gate
        let coordinator = fixture.coordinator()
        let enable = Task { await coordinator.setEnabledFromUser(true) }
        await fulfillment(of: [entered], timeout: 2)
        _ = await coordinator.setEnabledFromUser(false)
        gate.release()
        let allowed = await enable.value
        XCTAssertFalse(allowed)
        XCTAssertFalse(fixture.enabled)
        await coordinator.waitUntilIdle()
    }

    func testUncooperativeEnqueueAfterOptOut_RemovesItsRequestAndPreservesUnrelated() async {
        let fixture = NotificationFixture()
        let entered = expectation(description: "Enqueue entered")
        let gate = NotificationGate(entered: entered)
        fixture.enqueueGate = gate
        let existing = TranscriptReadyNotificationRoute.requestIdentifier(for: UUID())
        fixture.pending = [existing, "unrelated.remote-history"]
        let identifier = UUID()
        let coordinator = fixture.coordinator()
        coordinator.submit(.init(historyID: identifier))
        await fulfillment(of: [entered], timeout: 2)
        _ = await coordinator.setEnabledFromUser(false)
        let removalFinished = expectation(description: "Opt-out removes pending while enqueue remains held")
        let reenable = Task {
            let allowed = await coordinator.setEnabledFromUser(true)
            XCTAssertTrue(allowed)
            removalFinished.fulfill()
        }
        await fulfillment(of: [removalFinished], timeout: 2)
        XCTAssertEqual(fixture.pending, ["unrelated.remote-history"])
        fixture.enqueueGate = nil
        let newer = UUID()
        coordinator.submit(.init(historyID: newer))
        gate.release()
        await reenable.value
        await coordinator.waitUntilIdle()
        XCTAssertEqual(fixture.enqueued, [identifier, newer])
        XCTAssertEqual(fixture.pending, ["unrelated.remote-history",
                                      TranscriptReadyNotificationRoute.requestIdentifier(for: newer)])
        XCTAssertTrue(fixture.claimed.contains(identifier))
        fixture.enqueueGate = nil
        let allowed = await coordinator.setEnabledFromUser(true)
        XCTAssertTrue(allowed)
        let later = UUID()
        coordinator.submit(.init(historyID: later))
        await coordinator.waitUntilIdle()
        XCTAssertEqual(fixture.pending, ["unrelated.remote-history",
                                      TranscriptReadyNotificationRoute.requestIdentifier(for: newer),
                                      TranscriptReadyNotificationRoute.requestIdentifier(for: later)])
    }

    func testNotificationAndCaptureRouting_NewestIntentWinsWithoutStartingCapture() throws {
        let router = DeepLinkRouter()
        var superseded: [CaptureDeepLink] = []
        router.reportSupersededCapture = { superseded.append($0) }
        let queued = try XCTUnwrap(URL(string:
            "\(ReleaseTrain.current.urlScheme)://dictate?x-success=drafts://create&x-error=drafts://error"
        ))
        XCTAssertTrue(router.handle(queued))
        let capture = try XCTUnwrap(router.pendingCaptureAction)
        router.pendingConversationId = "old"
        let identifier = UUID()
        router.openHistory(identifier: identifier)
        XCTAssertEqual(superseded, [capture])
        XCTAssertNil(router.pendingCaptureAction)
        XCTAssertNil(router.pendingConversationId)
        XCTAssertEqual(router.pendingHistoryID, identifier)
        let newer = try XCTUnwrap(URL(string: "\(ReleaseTrain.current.urlScheme)://start?destination=history"))
        XCTAssertTrue(router.handle(newer))
        XCTAssertNil(router.pendingHistoryID)
        XCTAssertEqual(router.pendingCaptureAction?.action, .start)
        XCTAssertEqual(superseded, [capture], "Notification route is never an invented capture command")
    }

    func testPayloadAndNavigation_ExactUUIDWithoutTranscriptOrLatestFallback() throws {
        let identifier = UUID()
        let content = TranscriptReadyNotificationRoute.content(for: identifier)
        XCTAssertEqual(content.title, "Transcript ready")
        XCTAssertEqual(content.body, "Open History to view your saved transcription")
        XCTAssertNil(content.sound)
        XCTAssertNil(content.badge)
        XCTAssertEqual(Set(content.userInfo.keys), [AnyHashable("schema"), AnyHashable("historyID")])
        XCTAssertEqual(TranscriptReadyNotificationRoute.historyID(from: content.userInfo), identifier)
        XCTAssertNil(TranscriptReadyNotificationRoute.historyID(from: ["schema": 1, "historyID": "bad"]))
        XCTAssertNil(TranscriptReadyNotificationRoute.historyID(from: [
            "schema": 2, "historyID": identifier.uuidString
        ]))
        XCTAssertNil(TranscriptReadyNotificationRoute.historyID(from: [
            "schema": 1, "historyID": identifier.uuidString, "transcript": "private"
        ]))
        let router = DeepLinkRouter()
        XCTAssertNil(router.pendingCaptureAction)
        router.openHistory(identifier: identifier)
        XCTAssertEqual(router.pendingHistoryID, identifier)
        XCTAssertNil(router.pendingCaptureAction)
        let newest = iOSHistoryItem(transcription: "Other transcript", model: "test", duration: 1, wordCount: 2)
        XCTAssertNil(TranscriptReadyNotificationRoute.savedItem(identifier: identifier, items: [newest]))
        let exact = iOSHistoryItem(id: identifier, transcription: "Requested", model: "test", duration: 1, wordCount: 1)
        XCTAssertEqual(TranscriptReadyNotificationRoute.savedItem(identifier: identifier, items: [newest, exact])?.id,
                       identifier)
        let url = try XCTUnwrap(URL(string: "\(ReleaseTrain.current.urlScheme)://transcribe"))
        XCTAssertTrue(router.handle(url))
        XCTAssertNil(router.pendingHistoryID, "Later explicit navigation supersedes a stale notification route")
        XCTAssertNil(router.pendingCaptureAction)
    }
}

@MainActor
private final class NotificationFixture {
    var enabled = true
    var authorized = true
    var permissionGranted = true
    var permissionRequests = 0
    var authorizationReads = 0
    var claimFails = false
    var enqueueFails = false
    var claimed: Set<UUID> = []
    var enqueued: [UUID] = []
    var pending: [String] = []
    var authorizationGate: NotificationGate?
    var permissionGate: NotificationGate?
    var enqueueGate: NotificationGate?

    func coordinator() -> TranscriptReadyNotificationCoordinator {
        TranscriptReadyNotificationCoordinator(
            center: .init(
                authorized: {
                    self.authorizationReads += 1
                    await self.authorizationGate?.wait()
                    return self.authorized
                },
                requestAlertPermission: {
                    self.permissionRequests += 1
                    await self.permissionGate?.wait()
                    return self.permissionGranted
                },
                enqueue: { identifier in
                    XCTAssertTrue(self.claimed.contains(identifier), "Claim must persist before enqueue")
                    self.enqueued.append(identifier)
                    await self.enqueueGate?.wait()
                    if self.enqueueFails { throw CocoaError(.fileWriteUnknown) }
                    self.pending.append(TranscriptReadyNotificationRoute.requestIdentifier(for: identifier))
                },
                pendingIdentifiers: { self.pending },
                removePending: { identifiers in self.pending.removeAll { identifiers.contains($0) } }
            ),
            isEnabled: { self.enabled },
            writeEnabled: { self.enabled = $0 },
            claim: { identifier, _ in
                if self.claimFails { throw CocoaError(.fileWriteNoPermission) }
                return self.claimed.insert(identifier).inserted
            }
        )
    }
}

@MainActor
private final class NotificationGate {
    let entered: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    init(entered: XCTestExpectation) { self.entered = entered }
    func wait() async {
        await withCheckedContinuation { continuation in
            if self.released { continuation.resume() } else { self.continuation = continuation }
            self.entered.fulfill()
        }
    }
    func release() {
        self.released = true
        self.continuation?.resume()
        self.continuation = nil
    }
}
#endif
