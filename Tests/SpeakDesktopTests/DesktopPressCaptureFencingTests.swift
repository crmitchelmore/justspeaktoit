import Foundation
import SpeakDesktop
import XCTest

final class DesktopPressCaptureFencingTests: XCTestCase {
    func testDisabledUnavailablePermissionAndOtherOwners_NeverCallOpen() async throws {
        let admissions: [DesktopPressCaptureAdmission] = [
            pressCaptureAdmission(enabled: false),
            pressCaptureAdmission(capability: .unavailable("Wayland timing unqualified")),
            pressCaptureAdmission(permission: .unavailable("Unknown permission")),
            pressCaptureAdmission(owner: .manual), pressCaptureAdmission(owner: .handsFree),
            pressCaptureAdmission(owner: .comparison), pressCaptureAdmission(owner: .startup),
            pressCaptureAdmission(owner: .shutdown)
        ]
        let worker = PressCaptureTestWorker()
        let log = PressCaptureTestLog()
        let lease = DesktopPressCaptureLease(worker: worker, onFailure: log.fail)
        for admission in admissions {
            let refusal = try XCTUnwrap(admission.refusal)
            await assertPressError(.refused(refusal)) {
                _ = try await lease.begin(
                    identity: pressCaptureIdentity(), admission: admission, limits: pressCaptureLimits()
                )
            }
        }
        let opens = await worker.opens
        XCTAssertTrue(opens.isEmpty)
        XCTAssertEqual(admissions.first?.refusal, .disabled)
        XCTAssertEqual(admissions[1].refusal, .capabilityUnavailable("Wayland timing unqualified"))
    }

    func testDeviceRouteProfileRateAndFrameChange_InvalidateOpeningReservation() async throws {
        let changed = [
            pressCaptureIdentity(device: "other"), pressCaptureIdentity(route: "other"),
            pressCaptureIdentity(profile: "other"), pressCaptureIdentity(rate: 24_000),
            pressCaptureIdentity(frame: 20)
        ]
        for identity in changed {
            let worker = PressCaptureTestWorker(holdOpens: true)
            let log = PressCaptureTestLog()
            let lease = DesktopPressCaptureLease(worker: worker, onFailure: log.fail)
            let token = try await lease.begin(
                identity: pressCaptureIdentity(), admission: pressCaptureAdmission(), limits: pressCaptureLimits()
            )
            await worker.waitForOpens()
            await assertPressError(.identityChanged) {
                try await lease.reserve(token, identity: identity, admission: pressCaptureAdmission())
            }
            await assertPressPhase(lease, .closing)
            await worker.releaseOpens()
            try await lease.settle()
            await assertPressError(.staleLease) { try await lease.waitUntilReady(token) }
            let closes = await worker.closes
            XCTAssertEqual(closes.count, 1)
            XCTAssertTrue(log.pcm.isEmpty)
        }
    }

    func testAdmissionRevokedAfterReady_DisabledPermissionAndCaptureConflictsCloseReservation() async throws {
        let admissions = [
            pressCaptureAdmission(enabled: false),
            pressCaptureAdmission(permission: .unavailable("Revoked")),
            pressCaptureAdmission(capability: .unavailable("Route no longer qualified")),
            pressCaptureAdmission(owner: .handsFree), pressCaptureAdmission(owner: .manual),
            pressCaptureAdmission(owner: .comparison)
        ]
        for admission in admissions {
            let worker = PressCaptureTestWorker()
            let log = PressCaptureTestLog()
            let lease = DesktopPressCaptureLease(worker: worker, onFailure: log.fail)
            let identity = pressCaptureIdentity()
            let token = try await lease.begin(
                identity: identity, admission: pressCaptureAdmission(), limits: pressCaptureLimits()
            )
            try await lease.reserve(token, identity: identity, admission: pressCaptureAdmission())
            try await lease.waitUntilReady(token)
            await assertPressError(.refused(try XCTUnwrap(admission.refusal))) {
                try await lease.adopt(token, identity: identity, admission: admission, sink: log.append)
            }
            try await lease.settle()
            let closes = await worker.closes
            XCTAssertEqual(closes.count, 1)
            XCTAssertTrue(log.pcm.isEmpty)
        }
    }

    func testOpeningAndReadyCannotBeAdoptedWithoutReservation() async throws {
        let worker = PressCaptureTestWorker(holdOpens: true)
        let log = PressCaptureTestLog()
        let lease = DesktopPressCaptureLease(worker: worker, onFailure: log.fail)
        let identity = pressCaptureIdentity(), admission = pressCaptureAdmission()
        let token = try await lease.begin(identity: identity, admission: admission, limits: pressCaptureLimits())
        await worker.waitForOpens()
        await assertPressError(.invalidPhase) {
            try await lease.adopt(token, identity: identity, admission: admission, sink: log.append)
        }
        try await lease.reserve(token, identity: identity, admission: admission)
        await assertPressError(.notReady) {
            try await lease.adopt(token, identity: identity, admission: admission, sink: log.append)
        }
        await worker.releaseOpens()
        try await lease.waitUntilReady(token)
        try await lease.adopt(token, identity: identity, admission: admission, sink: log.append)
        await assertPressError(.invalidPhase) {
            try await lease.adopt(token, identity: identity, admission: admission, sink: log.append)
        }
        await lease.cancel(token)
        try await lease.settle()
    }

    func testOpenFailure_CleansPartialResourcesAndReportsFailure() async throws {
        let worker = PressCaptureTestWorker(failOpen: true)
        let log = PressCaptureTestLog()
        let lease = DesktopPressCaptureLease(worker: worker, onFailure: log.fail)
        _ = try await lease.begin(
            identity: pressCaptureIdentity(), admission: pressCaptureAdmission(), limits: pressCaptureLimits()
        )
        try await lease.settle()
        await assertPressPhase(lease, .idle)
        XCTAssertEqual(log.failures.count, 1)
        guard case .openFailed = log.failures.first else { return XCTFail("Missing native open failure") }
        let closes = await worker.closes
        XCTAssertEqual(closes.count, 1)
    }

    func testCloseFailure_RetainsExclusionAndExplicitRetryAcknowledgesCleanup() async throws {
        let worker = PressCaptureTestWorker(failedCloses: 1)
        let log = PressCaptureTestLog()
        let lease = DesktopPressCaptureLease(worker: worker, onFailure: log.fail)
        let identity = pressCaptureIdentity(), admission = pressCaptureAdmission()
        let token = try await lease.begin(identity: identity, admission: admission, limits: pressCaptureLimits())
        try await lease.waitUntilReady(token)
        await lease.cancel(token)
        do { try await lease.settle(); XCTFail("Close failure must not look settled") } catch {
            guard case .cleanupFailed = error as? DesktopPressCaptureError else { return XCTFail("\(error)") }
        }
        await assertPressPhase(lease, .closing)
        await lease.cancel(token)
        await assertPressError(.occupied) {
            _ = try await lease.begin(identity: identity, admission: admission, limits: pressCaptureLimits())
        }
        let firstCloses = await worker.closes
        XCTAssertEqual(firstCloses.count, 1)
        try await lease.retryClose(token)
        try await lease.settle()
        await assertPressPhase(lease, .idle)
        let finalCloses = await worker.closes
        XCTAssertEqual(finalCloses.count, 2)
        XCTAssertEqual(log.failures.count, 1)
    }

    func testCancelledReadinessWait_ClosesLateReservedCapture() async throws {
        let worker = PressCaptureTestWorker(holdOpens: true)
        let log = PressCaptureTestLog()
        let lease = DesktopPressCaptureLease(worker: worker, onFailure: log.fail)
        let identity = pressCaptureIdentity(), admission = pressCaptureAdmission()
        let token = try await lease.begin(identity: identity, admission: admission, limits: pressCaptureLimits())
        await worker.waitForOpens()
        try await lease.reserve(token, identity: identity, admission: admission)
        let waiter = Task { try await lease.waitUntilReady(token) }
        waiter.cancel()
        for _ in 0..<1_000 {
            if await lease.phase == .closing { break }
            await Task.yield()
        }
        await assertPressPhase(lease, .closing)
        await worker.releaseOpens()
        do { try await waiter.value; XCTFail("Cancelled reservation became ready") } catch is CancellationError {
            // Actual opening/cleanup still belongs to the lease, not this cancelled waiter.
        }
        try await lease.settle()
        let closes = await worker.closes
        XCTAssertEqual(closes.count, 1)
        XCTAssertTrue(log.pcm.isEmpty)
    }

    func testChangedIdentityAtAdoption_ClosesRatherThanDeliveringStalePCM() async throws {
        let worker = PressCaptureTestWorker()
        let log = PressCaptureTestLog()
        let lease = DesktopPressCaptureLease(worker: worker, onFailure: log.fail)
        let identity = pressCaptureIdentity(), admission = pressCaptureAdmission()
        let token = try await lease.begin(identity: identity, admission: admission, limits: pressCaptureLimits())
        try await lease.reserve(token, identity: identity, admission: admission)
        try await lease.waitUntilReady(token)
        await worker.emit(Data([1, 0]))
        await assertPressError(.identityChanged) {
            try await lease.adopt(
                token, identity: pressCaptureIdentity(device: "replacement"), admission: admission, sink: log.append
            )
        }
        try await lease.settle()
        XCTAssertTrue(log.pcm.isEmpty)
        let closes = await worker.closes
        XCTAssertEqual(closes.count, 1)
    }

    func testOverflowRacingAdoption_IsReportedOnceAndCleansUp() async throws {
        let worker = PressCaptureTestWorker()
        let log = PressCaptureTestLog()
        let lease = DesktopPressCaptureLease(worker: worker, onFailure: log.fail)
        let identity = pressCaptureIdentity(), admission = pressCaptureAdmission()
        let token = try await lease.begin(identity: identity, admission: admission, limits: pressCaptureLimits())
        try await lease.reserve(token, identity: identity, admission: admission)
        try await lease.waitUntilReady(token)
        await worker.emit(Data(repeating: 0, count: 34))
        do {
            try await lease.adopt(token, identity: identity, admission: admission, sink: log.append)
            XCTFail("Overflow cannot adopt")
        } catch {
            XCTAssertTrue(error as? DesktopPressCaptureError == .invalidPhase ||
                error as? DesktopPressCaptureError == .staleLease)
        }
        try await lease.settle()
        XCTAssertEqual(log.failures, [.startupOverflow])
        XCTAssertTrue(log.pcm.isEmpty)
        let closes = await worker.closes
        XCTAssertEqual(closes.count, 1)
    }

    func testInvalidFormat_DoesNotOpenNativeWorker() async throws {
        let worker = PressCaptureTestWorker()
        let log = PressCaptureTestLog()
        let lease = DesktopPressCaptureLease(worker: worker, onFailure: log.fail)
        for identity in [
            pressCaptureIdentity(rate: 0), pressCaptureIdentity(route: ""), pressCaptureIdentity(frame: 0)
        ] {
            await assertPressError(.invalidConfiguration) {
                _ = try await lease.begin(
                    identity: identity, admission: pressCaptureAdmission(), limits: pressCaptureLimits()
                )
            }
        }
        let opens = await worker.opens
        XCTAssertTrue(opens.isEmpty)
    }
}
