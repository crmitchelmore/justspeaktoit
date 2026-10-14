import Foundation
import SpeakDesktop
import XCTest

final class DesktopPressCapturePCMRelayTests: XCTestCase {
    func testRollingPCM_IsSampleAlignedAndBoundedUntilLosslessReservation() async throws {
        let log = PressCaptureTestLog()
        let relay = DesktopPressCapturePCMRelay(
            limits: try DesktopPressCaptureBufferLimits(preRollFrames: 2, reservedFrames: 4), onFailure: log.fail
        )
        XCTAssertTrue(relay.receive(Data([1, 0, 2, 0, 3, 0])))
        XCTAssertEqual(relay.bufferedBytes, 4)
        try relay.reserve()
        XCTAssertTrue(relay.receive(Data([4, 0, 5, 0])))
        XCTAssertEqual(relay.bufferedBytes, 8)
        XCTAssertTrue(log.pcm.isEmpty)
        try relay.attach(log.append)
        relay.close()
        try await relay.settleDelivery()
        XCTAssertEqual(log.pcm, Data([2, 0, 3, 0, 4, 0, 5, 0]))
        XCTAssertEqual(relay.bufferedBytes, 0)
        XCTAssertFalse(relay.receive(Data([6, 0])))
        XCTAssertTrue(log.failures.isEmpty)
    }

    func testReservedOverflow_FailsOnceRatherThanTruncatingAndCannotAttach() {
        let log = PressCaptureTestLog()
        let relay: DesktopPressCapturePCMRelay
        do {
            relay = DesktopPressCapturePCMRelay(
                limits: try DesktopPressCaptureBufferLimits(preRollFrames: 2, reservedFrames: 3), onFailure: log.fail
            )
            try relay.reserve()
        } catch { return XCTFail("\(error)") }
        XCTAssertTrue(relay.receive(Data([1, 0, 2, 0, 3, 0])))
        for _ in 0..<100 { XCTAssertFalse(relay.receive(Data([4, 0]))) }
        XCTAssertEqual(log.failures, [.startupOverflow])
        XCTAssertEqual(relay.bufferedBytes, 0)
        XCTAssertThrowsError(try relay.attach(log.append))
        XCTAssertTrue(log.pcm.isEmpty)
    }

    func testInvalidPCMAndInvalidLimits_AreExplicitNotCoerced() throws {
        let log = PressCaptureTestLog()
        let relay = DesktopPressCapturePCMRelay(limits: try pressCaptureLimits(), onFailure: log.fail)
        XCTAssertFalse(relay.receive(Data([1])))
        XCTAssertFalse(relay.receive(Data([1])))
        XCTAssertEqual(log.failures, [.invalidPCM])
        XCTAssertThrowsError(try DesktopPressCaptureBufferLimits(preRollFrames: 0, reservedFrames: 1))
        XCTAssertThrowsError(try DesktopPressCaptureBufferLimits(preRollFrames: 2, reservedFrames: 1))
        XCTAssertThrowsError(try DesktopPressCaptureBufferLimits(preRollFrames: 1, reservedFrames: Int.max))
    }

    func testAttachAndPCMRace_PreservesEveryReservedFrameExactlyOnce() async throws {
        let log = PressCaptureTestLog()
        let relay = DesktopPressCapturePCMRelay(
            limits: try DesktopPressCaptureBufferLimits(preRollFrames: 2, reservedFrames: 1_000), onFailure: log.fail
        )
        try relay.reserve()
        DispatchQueue.concurrentPerform(iterations: 101) { index in
            if index == 0 {
                do { try relay.attach(log.append) } catch { XCTFail("\(error)") }
            } else {
                XCTAssertTrue(relay.receive(Data([UInt8(index), 0])))
            }
        }
        relay.close()
        try await relay.settleDelivery()
        let values = stride(from: 0, to: log.pcm.count, by: 2).map { Int(log.pcm[$0]) }
        XCTAssertEqual(values.sorted(), Array(1...100))
        XCTAssertTrue(log.failures.isEmpty)
    }

    func testPCMAndCloseRace_DrainsExactlyTheFramesAdmittedBeforeFence() async throws {
        for _ in 0..<20 {
            let log = PressCaptureTestLog()
            let relay = DesktopPressCapturePCMRelay(
                limits: try DesktopPressCaptureBufferLimits(preRollFrames: 2, reservedFrames: 1_000),
                onFailure: log.fail
            )
            try relay.reserve()
            try relay.attach(log.append)
            DispatchQueue.concurrentPerform(iterations: 101) { index in
                if index == 50 {
                    relay.close()
                } else if relay.receive(Data([UInt8(index), 0])) {
                    log.accept(index)
                }
            }
            relay.close()
            try await relay.settleDelivery()
            let values = stride(from: 0, to: log.pcm.count, by: 2).map { Int(log.pcm[$0]) }
            XCTAssertEqual(values.sorted(), log.accepted.sorted())
            XCTAssertEqual(Set(values).count, values.count)
            XCTAssertTrue(log.failures.isEmpty)
        }
    }

    func testClose_JoinsActiveSinkOutsideLockAndCallbackMayReenterFence() async throws {
        let log = PressCaptureTestLog()
        let relay = DesktopPressCapturePCMRelay(limits: try pressCaptureLimits(), onFailure: log.fail)
        let entered = expectation(description: "Sink entered")
        let release = DispatchSemaphore(value: 0)
        try relay.reserve()
        try relay.attach { data in
            XCTAssertGreaterThan(relay.bufferedBytes, 0)
            relay.close()
            entered.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            log.append(data)
        }
        XCTAssertTrue(relay.receive(Data([1, 0])))
        await fulfillment(of: [entered], timeout: 2)
        relay.close()
        XCTAssertFalse(relay.receive(Data([2, 0])))
        XCTAssertTrue(log.pcm.isEmpty)
        release.signal()
        try await relay.settleDelivery()
        XCTAssertEqual(log.pcm, Data([1, 0]))
    }

    func testAttachedOverflow_DeliversEarlierAdmittedFramesAndSignalsOnce() async throws {
        let log = PressCaptureTestLog()
        let relay = DesktopPressCapturePCMRelay(
            limits: try DesktopPressCaptureBufferLimits(preRollFrames: 1, reservedFrames: 2), onFailure: log.fail
        )
        let entered = expectation(description: "Sink holding admitted PCM")
        let release = DispatchSemaphore(value: 0)
        try relay.reserve()
        try relay.attach { data in
            entered.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            log.append(data)
        }
        XCTAssertTrue(relay.receive(Data([1, 0, 2, 0])))
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertFalse(relay.receive(Data([3, 0])))
        XCTAssertFalse(relay.receive(Data([4, 0])))
        XCTAssertEqual(log.failures, [.startupOverflow])
        release.signal()
        relay.close()
        try await relay.settleDelivery()
        XCTAssertEqual(log.pcm, Data([1, 0, 2, 0]))
    }

    func testSettleWithoutFence_DoesNotClaimFutureDeliveryHasJoined() async throws {
        let log = PressCaptureTestLog()
        let relay = DesktopPressCapturePCMRelay(limits: try pressCaptureLimits(), onFailure: log.fail)
        do { try await relay.settleDelivery(); XCTFail("Unfenced delivery cannot settle") } catch {
            XCTAssertEqual(error as? DesktopPressCaptureError, .invalidPhase)
        }
        relay.close()
        try await relay.settleDelivery()
    }
}
