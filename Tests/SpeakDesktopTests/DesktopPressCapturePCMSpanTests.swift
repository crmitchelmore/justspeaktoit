import Foundation
@testable import SpeakDesktop
import XCTest

private func spanPCM(_ samples: [UInt8]) -> Data { Data(samples.flatMap { [$0, 0] }) }

private func spanRelay(_ log: PressCaptureTestLog, preRoll: Int = 2, reserved: Int = 4) throws
    -> DesktopPressCapturePCMRelay {
    DesktopPressCapturePCMRelay(
        limits: try DesktopPressCaptureBufferLimits(preRollFrames: preRoll, reservedFrames: reserved),
        onFailure: log.fail
    )
}

private func attachSpans(_ relay: DesktopPressCapturePCMRelay, to log: PressCaptureTestLog) throws {
    let token = DesktopPressCaptureToken(), identity = pressCaptureIdentity()
    try relay.attachDelivery { log.observe(DesktopPressCapturePCMDelivery(token: token, identity: identity, pcm: $0)) }
}

final class DesktopPressCapturePCMSpanTests: XCTestCase {
    func testGatedProducer_CompletedBeforeOrAfterReserveDefinesSampleRegions() async throws {
        for before in [true, false] {
            let log = PressCaptureTestLog()
            let relay = try spanRelay(log)
            let producer = PressCaptureTestProducer(data: spanPCM([1, 2])) { XCTAssertTrue(relay.receive($0)) }
            let send = Task { await producer.send() }
            await producer.waitUntilPending()
            if before {
                await producer.release()
                await send.value
                try relay.reserve()
            } else {
                try relay.reserve()
                await producer.release()
                await send.value
            }
            try attachSpans(relay, to: log)
            relay.close()
            try await relay.settleDelivery()
            let delivery = try XCTUnwrap(log.deliveries.first)
            XCTAssertEqual(delivery.data, spanPCM([1, 2]))
            XCTAssertEqual(delivery.beforeReservationSampleCount, before ? 2 : 0)
            XCTAssertEqual(log.deliveries.count, 1)
        }
    }

    func testRollingSuffixAndReservedBacklog_ShareExactPayloadSampleOffsets() async throws {
        let log = PressCaptureTestLog()
        let relay = try spanRelay(log)
        XCTAssertTrue(relay.receive(spanPCM([1, 2, 3, 4])))
        XCTAssertEqual(relay.bufferedBytes, 4)
        try relay.reserve()
        XCTAssertTrue(relay.receive(spanPCM([5, 6])))
        XCTAssertEqual(relay.bufferedBytes, 8)
        try attachSpans(relay, to: log)
        relay.close()
        try await relay.settleDelivery()
        let delivery = try XCTUnwrap(log.deliveries.first)
        XCTAssertEqual(delivery.data, spanPCM([3, 4, 5, 6]))
        XCTAssertEqual(delivery.beforeReservationSamples, 0..<2)
        XCTAssertEqual(delivery.afterReservationSamples, 2..<4)
        XCTAssertEqual(relay.bufferedBytes, 0)
    }

    func testZeroOrWholePrefix_EmptyReceivesDoNotCreateEmptyBatches() async throws {
        for before in [true, false] {
            let log = PressCaptureTestLog()
            let relay = try spanRelay(log)
            XCTAssertTrue(relay.receive(Data()))
            if before { XCTAssertTrue(relay.receive(spanPCM([1]))) }
            try relay.reserve()
            if !before { XCTAssertTrue(relay.receive(spanPCM([1]))) }
            XCTAssertTrue(relay.receive(Data()))
            try attachSpans(relay, to: log)
            relay.close()
            try await relay.settleDelivery()
            XCTAssertEqual(log.deliveries.count, 1)
            let delivery = try XCTUnwrap(log.deliveries.first)
            XCTAssertEqual(delivery.beforeReservationSamples, 0..<(before ? 1 : 0))
            XCTAssertEqual(delivery.afterReservationSamples, (before ? 1 : 0)..<1)
        }
    }

    func testConcurrentSubmissions_AllowEitherLegalReservationOrder() async throws {
        for _ in 0..<20 {
            let log = PressCaptureTestLog()
            let relay = try spanRelay(log)
            XCTAssertTrue(relay.receive(spanPCM([1])))
            DispatchQueue.concurrentPerform(iterations: 2) { index in
                if index == 0 {
                    do { try relay.reserve() } catch { XCTFail("\(error)") }
                } else {
                    XCTAssertTrue(relay.receive(spanPCM([2])))
                }
            }
            try attachSpans(relay, to: log)
            relay.close()
            try await relay.settleDelivery()
            let delivery = try XCTUnwrap(log.deliveries.first)
            XCTAssertEqual(delivery.data, spanPCM([1, 2]))
            XCTAssertTrue([1, 2].contains(delivery.beforeReservationSampleCount))
        }
    }

    func testAbandonedReservationAndOddPCM_DiscardUndeliveredMetadata() async throws {
        for invalid in [false, true] {
            let log = PressCaptureTestLog()
            let relay = try spanRelay(log)
            XCTAssertTrue(relay.receive(spanPCM([1])))
            try relay.reserve()
            if invalid {
                XCTAssertFalse(relay.receive(Data([1])))
                XCTAssertFalse(relay.receive(Data([1])))
                XCTAssertEqual(log.failures, [.invalidPCM])
            }
            relay.close()
            try await relay.settleDelivery()
            XCTAssertThrowsError(try attachSpans(relay, to: log))
            XCTAssertEqual(relay.bufferedBytes, 0)
            XCTAssertTrue(log.deliveries.isEmpty)
        }
    }

    func testReservedOverflow_ReportsOnceAndCannotProjectPartialSuccess() async throws {
        let log = PressCaptureTestLog()
        let relay = try spanRelay(log, reserved: 2)
        XCTAssertTrue(relay.receive(spanPCM([1])))
        try relay.reserve()
        XCTAssertTrue(relay.receive(spanPCM([2])))
        XCTAssertFalse(relay.receive(spanPCM([3])))
        XCTAssertFalse(relay.receive(spanPCM([4])))
        XCTAssertEqual(log.failures, [.startupOverflow])
        XCTAssertThrowsError(try attachSpans(relay, to: log))
        relay.close()
        try await relay.settleDelivery()
        XCTAssertEqual(relay.bufferedBytes, 0)
        XCTAssertTrue(log.deliveries.isEmpty)
    }

    func testReentrantSink_ClosesOutsideLockAndJoinsOnlyAdmittedPayload() async throws {
        let log = PressCaptureTestLog()
        let relay = try spanRelay(log)
        XCTAssertTrue(relay.receive(spanPCM([1])))
        try relay.reserve()
        let token = DesktopPressCaptureToken()
        try relay.attachDelivery { pcm in
            XCTAssertEqual(relay.bufferedBytes, 2)
            relay.close()
            XCTAssertFalse(relay.receive(spanPCM([2])))
            log.observe(DesktopPressCapturePCMDelivery(token: token, identity: pressCaptureIdentity(), pcm: pcm))
        }
        relay.close()
        try await relay.settleDelivery()
        XCTAssertEqual(log.deliveries.map(\.data), [spanPCM([1])])
        XCTAssertEqual(log.deliveries.first?.beforeReservationSampleCount, 1)
        XCTAssertEqual(relay.bufferedBytes, 0)
    }
}

extension DesktopPressCapturePCMSpanTests {
    func testLegacyIgnoredArgumentTrailingClosure_CompilesAndDeliversExactlyOnce() async throws {
        let worker = PressCaptureTestWorker()
        let log = PressCaptureTestLog()
        let lease = DesktopPressCaptureLease(worker: worker, onFailure: log.fail)
        let identity = pressCaptureIdentity(), admission = pressCaptureAdmission()
        let token = try await lease.begin(identity: identity, admission: admission, limits: pressCaptureLimits())
        try await lease.waitUntilReady(token)
        await worker.emit(spanPCM([1]))
        try await lease.reserve(token, identity: identity, admission: admission)
        try await lease.adopt(token, identity: identity, admission: admission) { _ in
            log.accept(1)
        }
        await lease.cancel(token)
        try await lease.settle()
        XCTAssertEqual(log.accepted, [1])
        XCTAssertTrue(log.failures.isEmpty)
        let closes = await worker.closes
        XCTAssertEqual(closes, [token.id])
    }

    func testActiveCanonicalSink_IsImmutableAndLegacyReceivesIdenticalBatches() async throws {
        let canonical = try await projectedBatches(legacy: false)
        let legacy = try await projectedBatches(legacy: true)
        XCTAssertEqual(canonical.batches, [spanPCM([1, 2, 3]), spanPCM([4])])
        XCTAssertEqual(canonical.batches, legacy.batches)
        XCTAssertEqual(canonical.deliveries.map(\.beforeReservationSampleCount), [2, 0])
        XCTAssertTrue(legacy.deliveries.isEmpty)
    }

    private func projectedBatches(legacy: Bool) async throws -> PressCaptureTestLog {
        let worker = PressCaptureTestWorker()
        let log = PressCaptureTestLog()
        let lease = DesktopPressCaptureLease(worker: worker, onFailure: log.fail)
        let identity = pressCaptureIdentity(), admission = pressCaptureAdmission()
        let token = try await lease.begin(identity: identity, admission: admission, limits: pressCaptureLimits())
        try await lease.waitUntilReady(token)
        await worker.emit(spanPCM([1, 2]))
        try await lease.reserve(token, identity: identity, admission: admission)
        await worker.emit(spanPCM([3]))
        let entered = expectation(description: "First batch held")
        let release = DispatchSemaphore(value: 0)
        let receive: @Sendable (Data) -> Void = {
            log.batch($0)
            if log.batches.count == 1 {
                entered.fulfill()
                XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            }
        }
        if legacy {
            try await lease.adopt(token, identity: identity, admission: admission, sink: receive)
        } else {
            try await lease.adoptDelivery(token, identity: identity, admission: admission, onPCMDelivery: {
                log.observe($0)
                receive($0.data)
            })
        }
        await fulfillment(of: [entered], timeout: 2)
        await worker.emit(spanPCM([4]))
        if !legacy {
            XCTAssertEqual(log.deliveries.first?.data, spanPCM([1, 2, 3]))
            XCTAssertEqual(log.deliveries.first?.token, token)
            XCTAssertEqual(log.deliveries.first?.identity, identity)
        }
        await lease.cancel(token)
        release.signal()
        try await lease.settle()
        XCTAssertTrue(log.failures.isEmpty)
        return log
    }

    func testAttachedOverflow_CountsInFlightSamplesAndPreservesImmutablePrefix() async throws {
        let log = PressCaptureTestLog()
        let relay = try spanRelay(log, reserved: 2)
        XCTAssertTrue(relay.receive(spanPCM([1])))
        try relay.reserve()
        XCTAssertTrue(relay.receive(spanPCM([2])))
        let entered = expectation(description: "Capacity in flight")
        let release = DispatchSemaphore(value: 0)
        let token = DesktopPressCaptureToken()
        try relay.attachDelivery { pcm in
            log.observe(DesktopPressCapturePCMDelivery(token: token, identity: pressCaptureIdentity(), pcm: pcm))
            entered.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
        }
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(relay.bufferedBytes, 4)
        XCTAssertFalse(relay.receive(spanPCM([3])))
        XCTAssertFalse(relay.receive(Data([1])))
        XCTAssertEqual(log.failures, [.startupOverflow])
        release.signal()
        relay.close()
        try await relay.settleDelivery()
        XCTAssertEqual(log.deliveries.map(\.data), [spanPCM([1, 2])])
        XCTAssertEqual(log.deliveries.first?.beforeReservationSampleCount, 1)
        XCTAssertEqual(relay.bufferedBytes, 0)
    }

    func testDelayedAAndLateCallbacks_RemainAWithoutPublishingIntoB() async throws {
        let worker = PressCaptureTestWorker()
        let log = PressCaptureTestLog()
        let lease = DesktopPressCaptureLease.observingFailures(worker: worker, onFailureEvent: log.observe)
        let firstIdentity = pressCaptureIdentity(device: "A")
        let first = try await lease.begin(
            identity: firstIdentity, admission: pressCaptureAdmission(), limits: pressCaptureLimits()
        )
        try await lease.waitUntilReady(first)
        await worker.emit(spanPCM([1]))
        try await lease.reserve(first, identity: firstIdentity, admission: pressCaptureAdmission())
        try await lease.adoptDelivery(
            first, identity: firstIdentity, admission: pressCaptureAdmission(), onPCMDelivery: log.observe
        )
        await lease.cancel(first)
        try await lease.settle()
        let secondIdentity = pressCaptureIdentity(device: "B")
        let second = try await lease.begin(
            identity: secondIdentity, admission: pressCaptureAdmission(), limits: pressCaptureLimits()
        )
        try await lease.waitUntilReady(second)
        for _ in 0..<100 {
            await worker.emit(Data([1]), id: first.id)
            await worker.fail(id: first.id, message: "late A")
        }
        await assertPressError(.staleLease) {
            try await lease.adoptDelivery(
                first, identity: firstIdentity, admission: pressCaptureAdmission(), onPCMDelivery: log.observe
            )
        }
        await assertPressPhase(lease, .open)
        let delayed = try XCTUnwrap(log.deliveries.first)
        XCTAssertEqual(delayed.token, first)
        XCTAssertEqual(delayed.identity, firstIdentity)
        XCTAssertEqual(delayed.beforeReservationSamples, 0..<1)
        XCTAssertNotEqual(delayed.token, second)
        XCTAssertEqual(log.deliveries.count, 1)
        XCTAssertTrue(log.events.isEmpty)
        await lease.cancel(second)
        try await lease.settle()
    }

    func testCleanupRetry_DoesNotRedeliverSpanOrNativeFinalPartialPCM() async throws {
        let worker = PressCaptureTestWorker(failedCloses: 1)
        let log = PressCaptureTestLog()
        let lease = DesktopPressCaptureLease.observingFailures(worker: worker, onFailureEvent: log.observe)
        let identity = pressCaptureIdentity(), admission = pressCaptureAdmission()
        let token = try await lease.begin(identity: identity, admission: admission, limits: pressCaptureLimits())
        try await lease.waitUntilReady(token)
        await worker.emit(spanPCM([1]))
        try await lease.reserve(token, identity: identity, admission: admission)
        try await lease.adoptDelivery(token, identity: identity, admission: admission, onPCMDelivery: log.observe)
        await lease.cancel(token)
        await assertPressError(.cleanupFailed("close")) { try await lease.settle() }
        await assertPressPhase(lease, .closing)
        await assertPressError(.occupied) {
            _ = try await lease.begin(identity: identity, admission: admission, limits: pressCaptureLimits())
        }
        try await lease.retryClose(token)
        try await lease.settle()
        XCTAssertEqual(log.deliveries.map(\.data), [spanPCM([1])])
        XCTAssertEqual(log.events.map(\.error), [.cleanupFailed("close")])
        let closes = await worker.closes
        XCTAssertEqual(closes, [token.id, token.id])
    }
}
