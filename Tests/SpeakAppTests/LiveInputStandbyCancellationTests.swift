import Foundation
import XCTest

@testable import SpeakApp

final class LiveInputStandbyCancellationTests: XCTestCase {
    private final class FakeEngine {}

    func testCancelRefill_BeforeTheWorkerStarts_DoesNotBuild() {
        var builds = 0
        let standby = LiveInputStandby(
            makeEngine: {
                builds += 1
                return FakeEngine()
            },
            currentInputDeviceID: { 42 }
        )
        let queued = standby.beginRefill()

        standby.cancelRefill()
        standby.refill(queued)

        XCTAssertEqual(builds, 0)
        XCTAssertNil(standby.stockedInputDeviceID)
    }

    func testCancelRefill_DoesNotWaitForABlockedBuildOrRestockItsResult() async {
        let building = expectation(description: "speculative build is blocked")
        let built = expectation(description: "retired build has finished")
        let finishBuild = DispatchSemaphore(value: 0)
        let standby = LiveInputStandby(
            makeEngine: {
                building.fulfill()
                XCTAssertEqual(finishBuild.wait(timeout: .now() + 5), .success)
                return FakeEngine()
            },
            currentInputDeviceID: { 42 }
        )
        DispatchQueue.global().async {
            standby.refill()
            built.fulfill()
        }
        await fulfillment(of: [building], timeout: 2)

        let start = ProcessInfo.processInfo.systemUptime
        standby.cancelRefill()
        XCTAssertNil(standby.take(matching: 42))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.1)

        finishBuild.signal()
        await fulfillment(of: [built], timeout: 2)
        XCTAssertNil(standby.stockedInputDeviceID)
    }

    func testStock_DuringABlockedRefill_IsNotOverwrittenByTheOlderBuild() async {
        let building = expectation(description: "older refill is blocked")
        let built = expectation(description: "older refill has finished")
        let finishBuild = DispatchSemaphore(value: 0)
        let standby = LiveInputStandby(
            makeEngine: {
                building.fulfill()
                XCTAssertEqual(finishBuild.wait(timeout: .now() + 5), .success)
                return FakeEngine()
            },
            currentInputDeviceID: { 42 }
        )
        DispatchQueue.global().async {
            standby.refill()
            built.fulfill()
        }
        await fulfillment(of: [building], timeout: 2)

        let stopped = FakeEngine()
        standby.stock(stopped, inputDeviceID: 42)
        finishBuild.signal()
        await fulfillment(of: [built], timeout: 2)

        XCTAssertTrue(standby.take(matching: 42) === stopped)
    }

    func testForegroundStartup_HasNoAwaitOnSpeculativeStandbyWork() throws {
        let appSources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/SpeakApp")
        for name in ["MainManager.swift", "MainManager+PressPrimer.swift"] {
            let source = try String(contentsOf: appSources.appendingPathComponent(name), encoding: .utf8)
            XCTAssertFalse(source.contains("settleStandby"), name)
        }
    }
}
