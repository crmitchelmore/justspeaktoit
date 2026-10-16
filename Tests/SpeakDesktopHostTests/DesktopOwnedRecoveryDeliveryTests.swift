import Foundation
import SpeakDesktop
@testable import SpeakDesktopHost
import XCTest

final class DesktopOwnedRecoveryDeliveryTests: XCTestCase {
    private let identity = DesktopPressCaptureIdentity(
        deviceID: "synthetic", routeID: "fixture", profileID: "frozen",
        sampleRate: 24_000, frameMilliseconds: 100
    )
    private let admission = DesktopPressCaptureAdmission(
        enabled: true, capability: .qualified, permission: .granted, owner: .idle
    )

    private func lease(
        _ worker: DictationFixtureWorker, recovery: DictationFixtureBytes, errors: DictationFixtureBytes
    ) -> DesktopPressCaptureLease {
        .recoveringOwned(worker: worker, recoveryDelivery: recovery.append, onFailureEvent: errors.failure)
    }

    func testOpenEmits73ValidSamplesThenThrows_RecoveryDrainsBeforeRetirement() async throws {
        let worker = DictationFixtureWorker()
        let pcm = dictationPCM(Array(Int16(1)...Int16(73)))
        await worker.configure(initial: pcm, tail: Data(), openFailure: true)
        let recovery = DictationFixtureBytes(), errors = DictationFixtureBytes()
        let lease = lease(worker, recovery: recovery, errors: errors)
        let ticket = try await lease.beginOwned(
            identity: identity, admission: admission,
            limits: DesktopPressCaptureBufferLimits(preRollFrames: 73, reservedFrames: 146)
        )
        try await waitForDictation { await worker.opens == 1 }
        try await ticket.release()
        XCTAssertEqual(recovery.data, pcm)
        XCTAssertTrue(errors.errors.contains { if case .openFailed = $0.error { return true }; return false })
        let events = await worker.events
        XCTAssertEqual(events, ["open", "quiescing", "quiesced", "retiring", "retired"])
    }

    func testCancelBeforeAdoption_AwaitsReadyQuiescenceAndPreservesPrefixPlusTail() async throws {
        let opening = DictationFixtureGate(open: false)
        let worker = DictationFixtureWorker(opening: opening)
        await worker.configure(initial: dictationPCM([101, 102]))
        let recovery = DictationFixtureBytes(), errors = DictationFixtureBytes()
        let lease = lease(worker, recovery: recovery, errors: errors)
        let ticket = try await lease.beginOwned(
            identity: identity, admission: admission,
            limits: DesktopPressCaptureBufferLimits(preRollFrames: 100, reservedFrames: 200)
        )
        try await waitForDictation { await worker.opens == 1 }
        let releasing = Task { try await ticket.release() }
        try await waitForDictation { await lease.phase == .closing }
        XCTAssertTrue(recovery.data.isEmpty)
        let before = await worker.retirements
        XCTAssertEqual(before, 0)
        await opening.release()
        try await releasing.value
        XCTAssertEqual(recovery.data, dictationPCM([101, 102] + Array(Int16(1)...Int16(73))))
        XCTAssertTrue(errors.errors.isEmpty)
    }

    func testSuccessfulAdoption_ReplaysPrefixOnceOnlyToNormalSinkAfterReadiness() async throws {
        let opening = DictationFixtureGate(open: false)
        let worker = DictationFixtureWorker(opening: opening)
        await worker.configure(initial: dictationPCM([91, 92]))
        let recovery = DictationFixtureBytes(), normal = DictationFixtureBytes(), errors = DictationFixtureBytes()
        let lease = lease(worker, recovery: recovery, errors: errors)
        let ticket = try await lease.beginOwned(
            identity: identity, admission: admission,
            limits: DesktopPressCaptureBufferLimits(preRollFrames: 100, reservedFrames: 200)
        )
        try await lease.reserve(ticket.token, identity: identity, admission: admission)
        try await waitForDictation { await worker.opens == 1 }
        XCTAssertTrue(normal.data.isEmpty)
        XCTAssertTrue(recovery.data.isEmpty)
        await opening.release()
        try await lease.waitUntilReady(ticket.token)
        try await lease.adoptDelivery(ticket.token, identity: identity, admission: admission, onPCMDelivery: normal.append)
        try await ticket.release()
        XCTAssertEqual(normal.data, dictationPCM([91, 92] + Array(Int16(1)...Int16(73))))
        XCTAssertTrue(recovery.data.isEmpty)
    }

    func testOverflowAndPartialFrame_KeepOnlyAdmittedWholePrefixAndReportFirstFailure() async throws {
        for malformed in [false, true] {
            let opening = DictationFixtureGate(open: false)
            let worker = DictationFixtureWorker(opening: opening)
            await worker.configure(initial: dictationPCM([1, 2]), tail: Data())
            let recovery = DictationFixtureBytes(), errors = DictationFixtureBytes()
            let lease = lease(worker, recovery: recovery, errors: errors)
            let ticket = try await lease.beginOwned(
                identity: identity, admission: admission,
                limits: DesktopPressCaptureBufferLimits(preRollFrames: 1, reservedFrames: 2)
            )
            try await waitForDictation { await worker.opens == 1 }
            await worker.emitLate(malformed ? Data([3]) : dictationPCM([3]))
            await opening.release()
            try await ticket.release()
            XCTAssertEqual(recovery.data, dictationPCM([1, 2]), "Never roll away accepted startup samples.")
            XCTAssertEqual(errors.errors.first?.error, malformed ? .invalidPCM : .startupOverflow)
        }
    }

    func testFailedRetirement_RetainsExclusionAndRetryDoesNotReplayRecovery() async throws {
        let worker = DictationFixtureWorker()
        await worker.configure(initial: dictationPCM([1, 2]), tail: Data(), retirementFailures: 1)
        let recovery = DictationFixtureBytes(), errors = DictationFixtureBytes()
        let lease = lease(worker, recovery: recovery, errors: errors)
        let limits = try DesktopPressCaptureBufferLimits(preRollFrames: 2, reservedFrames: 4)
        let ticket = try await lease.beginOwned(identity: identity, admission: admission, limits: limits)
        try await waitForDictation { await worker.opens == 1 }
        do { try await ticket.release(); XCTFail("Retirement must fail.") } catch {
            guard let failure = error as? DesktopPressCaptureError, case .cleanupFailed = failure else {
                XCTFail("Unexpected retirement error: \(error)")
                return
            }
        }
        do {
            _ = try await lease.beginOwned(identity: identity, admission: admission, limits: limits)
            XCTFail("Unsafe owner must exclude another capture.")
        } catch { XCTAssertEqual(error as? DesktopPressCaptureError, .occupied) }
        try await ticket.retryRelease()
        XCTAssertEqual(recovery.data, dictationPCM([1, 2]))
        let retirements = await worker.retirements
        XCTAssertEqual(retirements, 2)
    }

    func testOldLeaseWithoutRecovery_StillDiscardsUnadoptedPCM() async throws {
        let worker = DictationFixtureWorker()
        await worker.configure(initial: dictationPCM([1, 2]), tail: Data())
        let errors = DictationFixtureBytes(), normal = DictationFixtureBytes()
        let lease = DesktopPressCaptureLease.observingFailures(worker: worker, onFailureEvent: errors.failure)
        let ticket = try await lease.beginOwned(
            identity: identity, admission: admission,
            limits: DesktopPressCaptureBufferLimits(preRollFrames: 2, reservedFrames: 4)
        )
        try await lease.waitUntilReady(ticket.token)
        try await ticket.release()
        XCTAssertTrue(normal.data.isEmpty)
        let quiescences = await worker.quiescences
        XCTAssertEqual(quiescences, 0, "Legacy pre-adoption cancellation policy is unchanged.")
    }

    func testStaleTicketAndCallbacks_CannotReleaseOrContaminateReplacementRun() async throws {
        let worker = DictationFixtureWorker()
        await worker.configure(tail: dictationPCM([1]))
        let recovery = DictationFixtureBytes(), errors = DictationFixtureBytes()
        let lease = lease(worker, recovery: recovery, errors: errors)
        let limits = try DesktopPressCaptureBufferLimits(preRollFrames: 2, reservedFrames: 4)
        let first = try await lease.beginOwned(identity: identity, admission: admission, limits: limits)
        try await lease.waitUntilReady(first.token)
        try await first.release()
        let next = try await lease.beginOwned(identity: identity, admission: admission, limits: limits)
        try await lease.waitUntilReady(next.token)
        await worker.staleCallbacks()
        try await first.release()
        let phase = await lease.phase
        XCTAssertEqual(phase, .open)
        try await next.release()
        XCTAssertEqual(recovery.data, dictationPCM([1, 1]))
        XCTAssertFalse(errors.errors.contains { $0.error == .captureFailed("stale prior run failure") })
    }
}
