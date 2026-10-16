import Foundation
@testable import SpeakDesktop
import XCTest

private actor DeferredPressFailureReceiver {
    private var arrived = false
    private var arrival: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    private var completion: CheckedContinuation<Void, Never>?
    private(set) var events: [DesktopPressCaptureFailureEvent] = []

    func receive(_ event: DesktopPressCaptureFailureEvent) async {
        arrived = true
        arrival?.resume()
        arrival = nil
        await withCheckedContinuation { release = $0 }
        events.append(event)
        completion?.resume()
        completion = nil
    }

    func waitForArrival() async {
        if !arrived { await withCheckedContinuation { arrival = $0 } }
    }

    func process() async {
        release?.resume()
        release = nil
        if events.isEmpty { await withCheckedContinuation { completion = $0 } }
    }
}

final class DesktopPressCaptureFailureEventTests: XCTestCase {
    func testEventEquality_IncludesTokenEveryIdentityFieldAndError() {
        let token = DesktopPressCaptureToken()
        let identity = pressCaptureIdentity()
        let event = DesktopPressCaptureFailureEvent(token: token, identity: identity, error: .invalidPCM)
        XCTAssertEqual(event, DesktopPressCaptureFailureEvent(token: token, identity: identity, error: .invalidPCM))
        XCTAssertNotEqual(event, DesktopPressCaptureFailureEvent(
            token: DesktopPressCaptureToken(), identity: identity, error: .invalidPCM
        ))
        for changed in [
            pressCaptureIdentity(device: "other"), pressCaptureIdentity(route: "other"),
            pressCaptureIdentity(profile: "other"), pressCaptureIdentity(rate: 24_000),
            pressCaptureIdentity(frame: 20)
        ] {
            XCTAssertNotEqual(event, DesktopPressCaptureFailureEvent(
                token: token, identity: changed, error: .invalidPCM
            ))
        }
        XCTAssertNotEqual(event, DesktopPressCaptureFailureEvent(token: token, identity: identity, error: .notReady))
    }

    func testOpenAndCleanupFailures_KeepAdmittedIdentityAndExplicitRetry() async throws {
        let worker = PressCaptureTestWorker(failOpen: true, failedCloses: 1)
        let log = PressCaptureTestLog()
        let lease = DesktopPressCaptureLease.observingFailures(worker: worker, onFailureEvent: log.observe)
        let identity = pressCaptureIdentity(device: "opening-device", profile: "opening-profile")
        let token = try await lease.begin(
            identity: identity, admission: pressCaptureAdmission(), limits: pressCaptureLimits()
        )
        await assertPressError(.cleanupFailed("close")) { try await lease.settle() }
        XCTAssertEqual(log.events, [
            DesktopPressCaptureFailureEvent(token: token, identity: identity, error: .openFailed("open")),
            DesktopPressCaptureFailureEvent(token: token, identity: identity, error: .cleanupFailed("close"))
        ])
        let failure = await lease.failure
        XCTAssertEqual(failure, .cleanupFailed("close"))
        await assertPressPhase(lease, .closing)
        try await lease.retryClose(token)
        try await lease.settle()
        await assertPressPhase(lease, .idle)
        XCTAssertEqual(log.events.count, 2)
        let closes = await worker.closes
        XCTAssertEqual(closes, [token.id, token.id])
    }

    func testNativeInvalidPCMAndOverflow_ReportOnceWithSeparateCleanupCause() async throws {
        for expected in [
            DesktopPressCaptureError.captureFailed("native"), .invalidPCM, .startupOverflow
        ] {
            let worker = PressCaptureTestWorker(failedCloses: 1)
            let log = PressCaptureTestLog()
            let lease = DesktopPressCaptureLease.observingFailures(worker: worker, onFailureEvent: log.observe)
            let identity = pressCaptureIdentity(device: "device-\(expected)", route: "route-\(expected)")
            let token = try await lease.begin(
                identity: identity, admission: pressCaptureAdmission(), limits: pressCaptureLimits()
            )
            try await lease.reserve(token, identity: identity, admission: pressCaptureAdmission())
            try await lease.waitUntilReady(token)
            switch expected {
            case .captureFailed:
                await worker.fail(id: token.id, message: "native")
            case .invalidPCM:
                await worker.emit(Data([1]))
            default:
                await worker.emit(Data(repeating: 0, count: 34))
            }
            await worker.waitForCloses()
            await assertPressError(.cleanupFailed("close")) { try await lease.settle() }
            XCTAssertEqual(log.events, [
                DesktopPressCaptureFailureEvent(token: token, identity: identity, error: expected),
                DesktopPressCaptureFailureEvent(token: token, identity: identity, error: .cleanupFailed("close"))
            ])
            let failure = await lease.failure
            XCTAssertEqual(failure, .cleanupFailed("close"))
            await assertPressError(.occupied) {
                _ = try await lease.begin(
                    identity: identity, admission: pressCaptureAdmission(), limits: pressCaptureLimits()
                )
            }
            for _ in 0..<100 {
                await worker.fail(id: token.id, message: "repeated")
                await worker.emit(Data([1]), id: token.id)
            }
            try await lease.retryClose(token)
            try await lease.settle()
            XCTAssertEqual(log.events.count, 2)
            let closes = await worker.closes
            XCTAssertEqual(closes, [token.id, token.id])
        }
    }

    func testDeferredReceiver_ProcessesAAfterBWithoutRetaggingOrClosingB() async throws {
        let worker = PressCaptureTestWorker()
        let receiver = DeferredPressFailureReceiver()
        let log = PressCaptureTestLog()
        let lease = DesktopPressCaptureLease.observingFailures(worker: worker, onFailureEvent: { event in
            log.observe(event)
            Task { await receiver.receive(event) }
        })
        let firstIdentity = pressCaptureIdentity(device: "A-device", route: "A-route", profile: "A-profile")
        let first = try await lease.begin(
            identity: firstIdentity, admission: pressCaptureAdmission(), limits: pressCaptureLimits()
        )
        try await lease.waitUntilReady(first)
        await worker.fail(id: first.id, message: "A-failure")
        await receiver.waitForArrival()
        try await lease.settle()
        let secondIdentity = pressCaptureIdentity(device: "B-device", route: "B-route", profile: "B-profile")
        let second = try await lease.begin(
            identity: secondIdentity, admission: pressCaptureAdmission(), limits: pressCaptureLimits()
        )
        try await lease.waitUntilReady(second)
        let beforeProcessing = await receiver.events
        XCTAssertTrue(beforeProcessing.isEmpty)
        for _ in 0..<1_000 {
            await worker.fail(id: first.id, message: "late-A")
            await worker.emit(Data([1]), id: first.id)
        }
        await receiver.process()
        let processed = await receiver.events
        XCTAssertEqual(processed, [
            DesktopPressCaptureFailureEvent(token: first, identity: firstIdentity, error: .captureFailed("A-failure"))
        ])
        XCTAssertEqual(log.events, processed)
        await assertPressPhase(lease, .open)
        let failure = await lease.failure
        XCTAssertNil(failure)
        let closesBeforeBStop = await worker.closes
        XCTAssertEqual(closesBeforeBStop, [first.id])
        await lease.cancel(second)
        try await lease.settle()
        let closes = await worker.closes
        XCTAssertEqual(closes, [first.id, second.id])
        let maximumActive = await worker.maximumActive
        XCTAssertEqual(maximumActive, 1)
    }

    func testLegacyIgnoredArgumentInitializer_ReportsSeparateCleanupAndRetainsExclusion() async throws {
        let worker = PressCaptureTestWorker(failOpen: true, failedCloses: 1)
        let log = PressCaptureTestLog()
        let lease = DesktopPressCaptureLease(worker: worker) { _ in log.accept(1) }
        let identity = pressCaptureIdentity()
        let token = try await lease.begin(
            identity: identity, admission: pressCaptureAdmission(), limits: pressCaptureLimits()
        )
        await assertPressError(.cleanupFailed("close")) { try await lease.settle() }
        XCTAssertEqual(log.accepted, [1, 1])
        let failure = await lease.failure
        XCTAssertEqual(failure, .cleanupFailed("close"))
        await assertPressPhase(lease, .closing)
        await assertPressError(.occupied) {
            _ = try await lease.begin(
                identity: identity, admission: pressCaptureAdmission(), limits: pressCaptureLimits()
            )
        }
        try await lease.retryClose(token)
        try await lease.settle()
        await assertPressPhase(lease, .idle)
        XCTAssertEqual(log.accepted, [1, 1])
        let closes = await worker.closes
        XCTAssertEqual(closes, [token.id, token.id])
    }

    func testErrorOnlyInitializer_ProjectsOpenAndCleanupWithoutDuplicateSubscription() async throws {
        let worker = PressCaptureTestWorker(failOpen: true, failedCloses: 1)
        let log = PressCaptureTestLog()
        let lease = DesktopPressCaptureLease(worker: worker, onFailure: log.fail)
        let token = try await lease.begin(
            identity: pressCaptureIdentity(), admission: pressCaptureAdmission(), limits: pressCaptureLimits()
        )
        await assertPressError(.cleanupFailed("close")) { try await lease.settle() }
        XCTAssertEqual(log.failures, [.openFailed("open"), .cleanupFailed("close")])
        try await lease.retryClose(token)
        try await lease.settle()
        XCTAssertEqual(log.failures.count, 2)
    }
}
