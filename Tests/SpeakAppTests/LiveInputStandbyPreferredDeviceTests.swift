import XCTest

@testable import SpeakApp

final class LiveInputStandbyPreferredDeviceTests: XCTestCase {
    private final class FakeEngine {}

    func testRefill_PreferredInputRequiresSwitch_DoesNotBuildForTheOldDefault() {
        var builds = 0
        let standby = LiveInputStandby(
            makeEngine: {
                builds += 1
                return FakeEngine()
            },
            currentInputDeviceID: { 42 }
        )

        standby.refill(standby.beginRefill(preferredInputDeviceID: 99))

        XCTAssertEqual(builds, 0)
        XCTAssertNil(standby.stockedInputDeviceID)
    }

    func testRefill_PreferredInputMatchesDefault_BuildsAReusableEngine() {
        var builds = 0
        let engine = FakeEngine()
        let standby = LiveInputStandby(
            makeEngine: {
                builds += 1
                return engine
            },
            currentInputDeviceID: { 42 }
        )

        standby.refill(standby.beginRefill(preferredInputDeviceID: 42))

        XCTAssertEqual(builds, 1)
        XCTAssertTrue(standby.take(matching: 42) === engine)
    }

    func testRefill_SystemDefaultSelection_StillBuilds() {
        var builds = 0
        let standby = LiveInputStandby(
            makeEngine: {
                builds += 1
                return FakeEngine()
            },
            currentInputDeviceID: { 42 }
        )

        standby.refill(standby.beginRefill(preferredInputDeviceID: nil))

        XCTAssertEqual(builds, 1)
        XCTAssertEqual(standby.stockedInputDeviceID, 42)
    }

    func testRefill_AfterCloseRestoresDefault_PreservesTheStoppedPreferredEngine() {
        var builds = 0
        var deviceID: UInt32 = 42
        let standby = LiveInputStandby(
            makeEngine: {
                builds += 1
                return FakeEngine()
            },
            currentInputDeviceID: { deviceID }
        )
        let stopped = FakeEngine()
        standby.stock(stopped, inputDeviceID: 99)

        standby.refill(standby.beginRefill(preferredInputDeviceID: 99))
        XCTAssertEqual(builds, 0, "Restoring the default must not schedule another input-node build")
        XCTAssertEqual(standby.stockedInputDeviceID, 99)

        deviceID = 99
        XCTAssertTrue(standby.take(matching: deviceID) === stopped)
    }

    func testRefill_DefaultChangesDuringBuild_DoesNotStockTheOldDevice() {
        var deviceID: UInt32 = 42
        let standby = LiveInputStandby(
            makeEngine: {
                deviceID = 99
                return FakeEngine()
            },
            currentInputDeviceID: { deviceID }
        )

        standby.refill(standby.beginRefill(preferredInputDeviceID: 42))

        XCTAssertNil(standby.stockedInputDeviceID)
    }

    func testRefill_NewPreferredSelection_RetiresTheQueuedDefaultBuild() {
        var builds = 0
        let standby = LiveInputStandby(
            makeEngine: {
                builds += 1
                return FakeEngine()
            },
            currentInputDeviceID: { 42 }
        )
        let oldDefault = standby.beginRefill()
        standby.cancelRefill()
        let newPreference = standby.beginRefill(preferredInputDeviceID: 99)

        standby.refill(oldDefault)
        standby.refill(newPreference)

        XCTAssertEqual(builds, 0)
        XCTAssertNil(standby.stockedInputDeviceID)
    }
}
