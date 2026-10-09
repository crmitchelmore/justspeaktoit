import AVFoundation
import Foundation
import XCTest

@testable import SpeakApp

/// The key-down primer's running engine reaches the session through
/// `LiveInputEngineStore.adopt`. The store must strip the primer's tap before a
/// controller sees the engine, and stop the engine whenever it drops it — a
/// running engine holds the microphone, and building a fresh input node beside
/// it stalls for seconds on Bluetooth inputs.
final class LiveInputEngineStoreAdoptionTests: XCTestCase {

    private final class FakeEngine {
        var hasPrimerTap = true
        var isRunning = true
    }

    private final class Environment {
        var inputDeviceID: UInt32? = 42
        var log: [String] = []
        var handedOut: [FakeEngine] = []
        var released: [FakeEngine] = []

        lazy var hooks = LiveInputEngineStore<FakeEngine>.AdoptionHooks(
            willHandOut: { [unowned self] engine in
                engine.hasPrimerTap = false
                self.handedOut.append(engine)
                self.log.append("handOut")
            },
            release: { [unowned self] engine in
                engine.isRunning = false
                self.released.append(engine)
                self.log.append("release")
            }
        )
    }

    private func makeStore(_ environment: Environment) -> LiveInputEngineStore<FakeEngine> {
        LiveInputEngineStore(
            makeEngine: {
                environment.log.append("build")
                return FakeEngine()
            },
            primeInput: { _ in },
            currentInputDeviceID: { environment.inputDeviceID }
        )
    }

    func testMakeEngine_HandsOutTheAdoptedEngineWithoutThePrimerTap() {
        // Arrange
        let environment = Environment()
        let store = makeStore(environment)
        let token = store.beginPreparation()
        let primed = FakeEngine()

        // Act
        let adopted = store.adopt(primed, inputDeviceID: 42, token: token, hooks: environment.hooks)
        let engine = store.makeEngine()

        // Assert
        XCTAssertTrue(adopted)
        XCTAssertTrue(engine === primed)
        XCTAssertFalse(engine.hasPrimerTap)
        XCTAssertTrue(engine.isRunning)
        XCTAssertEqual(environment.log, ["handOut"])
    }

    func testAdopt_WithAStaleToken_LeavesTheEngineWithTheCaller() {
        // Arrange
        let environment = Environment()
        let store = makeStore(environment)
        let stale = store.beginPreparation()
        _ = store.beginPreparation()

        // Act
        let adopted = store.adopt(FakeEngine(), inputDeviceID: 42, token: stale, hooks: environment.hooks)

        // Assert
        XCTAssertFalse(adopted)
        XCTAssertFalse(store.hasPreparedEngine)
        XCTAssertTrue(environment.released.isEmpty)
    }

    func testMakeEngine_ForContinuousHandover_KeepsTheAdoptedTapRunning() {
        let environment = Environment()
        let store = makeStore(environment)
        let token = store.beginPreparation()
        let primed = FakeEngine()
        store.adopt(primed, inputDeviceID: 42, token: token, hooks: environment.hooks)

        let engine = store.makeEngine(preservingAdoptedTap: true)
        store.discard(token, releasingClaimed: true)

        XCTAssertTrue(engine === primed)
        XCTAssertTrue(engine.hasPrimerTap)
        XCTAssertFalse(engine.isRunning)
        XCTAssertEqual(environment.log, ["release"])
    }

    func testMakeEngine_ForAnotherDevice_StopsTheAdoptedEngineBeforeBuildingAFreshOne() {
        // Arrange
        let environment = Environment()
        let store = makeStore(environment)
        let token = store.beginPreparation()
        let primed = FakeEngine()
        store.adopt(primed, inputDeviceID: 42, token: token, hooks: environment.hooks)
        environment.inputDeviceID = 7

        // Act
        let engine = store.makeEngine()

        // Assert
        XCTAssertFalse(engine === primed)
        XCTAssertFalse(primed.isRunning)
        XCTAssertEqual(environment.log, ["release", "build"])
    }

    func testDiscard_StopsAnUnclaimedAdoptedEngine() {
        // Arrange
        let environment = Environment()
        let store = makeStore(environment)
        let token = store.beginPreparation()
        let primed = FakeEngine()
        store.adopt(primed, inputDeviceID: 42, token: token, hooks: environment.hooks)

        // Act
        store.discard(token)

        // Assert
        XCTAssertFalse(primed.isRunning)
        XCTAssertFalse(store.hasPreparedEngine)
    }

    func testDiscard_LeavesAClaimedAdoptedEngineRunning() {
        // Arrange
        let environment = Environment()
        let store = makeStore(environment)
        let token = store.beginPreparation()
        let primed = FakeEngine()
        store.adopt(primed, inputDeviceID: 42, token: token, hooks: environment.hooks)
        _ = store.makeEngine()

        // Act
        store.discard(token)

        // Assert
        XCTAssertTrue(primed.isRunning)
        XCTAssertTrue(environment.released.isEmpty)
    }

    func testBeginPreparation_StopsAnEarlierUnclaimedAdoptedEngine() {
        // Arrange
        let environment = Environment()
        let store = makeStore(environment)
        let token = store.beginPreparation()
        let primed = FakeEngine()
        store.adopt(primed, inputDeviceID: 42, token: token, hooks: environment.hooks)

        // Act
        _ = store.beginPreparation()

        // Assert
        XCTAssertFalse(primed.isRunning)
    }

    func testAdopt_ReplacingAnotherAdoptedEngine_StopsTheReplacedOne() {
        // Arrange
        let environment = Environment()
        let store = makeStore(environment)
        let token = store.beginPreparation()
        let first = FakeEngine()
        let second = FakeEngine()
        store.adopt(first, inputDeviceID: 42, token: token, hooks: environment.hooks)

        // Act
        store.adopt(second, inputDeviceID: 42, token: token, hooks: environment.hooks)
        let engine = store.makeEngine()

        // Assert
        XCTAssertFalse(first.isRunning)
        XCTAssertTrue(engine === second)
    }

    func testRestore_ReturnsTheAdoptedEngineForTheFallbackController() {
        // Arrange
        let environment = Environment()
        let store = makeStore(environment)
        let token = store.beginPreparation()
        let primed = FakeEngine()
        store.adopt(primed, inputDeviceID: 42, token: token, hooks: environment.hooks)
        let first = store.makeEngine()

        // Act
        store.restore(first)
        let fallback = store.makeEngine()

        // Assert
        XCTAssertTrue(fallback === primed)
        XCTAssertFalse(environment.log.contains("build"))
    }
}

final class LiveInputStandbyTests: XCTestCase {

    private final class FakeEngine {}

    private final class Environment {
        var inputDeviceID: UInt32? = 42
        var builds = 0
        /// Runs inside a build, to simulate the device changing mid-build.
        var duringBuild: (() -> Void)?
    }

    private func makeStandby(_ environment: Environment) -> LiveInputStandby<FakeEngine> {
        LiveInputStandby(
            makeEngine: {
                environment.builds += 1
                environment.duringBuild?()
                return FakeEngine()
            },
            currentInputDeviceID: { environment.inputDeviceID }
        )
    }

    func testTake_ForTheStockedDevice_HandsOutTheEngineOnce() {
        // Arrange
        let environment = Environment()
        let standby = makeStandby(environment)
        standby.refill()

        // Act
        let first = standby.take(matching: 42)
        let second = standby.take(matching: 42)

        // Assert
        XCTAssertNotNil(first)
        XCTAssertNil(second)
    }

    func testTake_ForAnotherDevice_DropsTheStandby() {
        // Arrange
        let environment = Environment()
        let standby = makeStandby(environment)
        standby.refill()

        // Act
        let mismatched = standby.take(matching: 7)

        // Assert
        XCTAssertNil(mismatched)
        XCTAssertNil(standby.stockedInputDeviceID)
    }

    func testRefill_WhenTheStandbyIsCurrent_DoesNotBuildAgain() {
        // Arrange
        let environment = Environment()
        let standby = makeStandby(environment)
        standby.refill()

        // Act
        standby.refill()

        // Assert
        XCTAssertEqual(environment.builds, 1)
    }

    func testRefill_AfterADeviceChange_RebuildsForTheNewDevice() {
        // Arrange
        let environment = Environment()
        let standby = makeStandby(environment)
        standby.refill()
        environment.inputDeviceID = 7

        // Act
        standby.refill()

        // Assert
        XCTAssertEqual(environment.builds, 2)
        XCTAssertEqual(standby.stockedInputDeviceID, 7)
    }

    func testRefill_WhenTheDeviceChangesMidBuild_KeepsNothing() {
        // Arrange
        let environment = Environment()
        let standby = makeStandby(environment)
        environment.duringBuild = { environment.inputDeviceID = 7 }

        // Act
        standby.refill()

        // Assert
        XCTAssertNil(standby.stockedInputDeviceID)
    }

    func testRefill_WithoutAnInputDevice_BuildsNothing() {
        // Arrange
        let environment = Environment()
        environment.inputDeviceID = nil
        let standby = makeStandby(environment)

        // Act
        standby.refill()

        // Assert
        XCTAssertEqual(environment.builds, 0)
    }

    func testStock_KeepsAClosedPrimerEngineForTheNextPress() {
        // Arrange
        let environment = Environment()
        let standby = makeStandby(environment)
        let engine = FakeEngine()

        // Act
        standby.stock(engine, inputDeviceID: 42)

        // Assert
        XCTAssertTrue(standby.take(matching: 42) === engine)
        XCTAssertEqual(environment.builds, 0)
    }
}

final class PrimerPreRollBufferTests: XCTestCase {

    private let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!

    private func buffer(frames: AVAudioFrameCount, value: Float) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for index in 0..<Int(frames) {
            buffer.floatChannelData![0][index] = value
        }
        return buffer
    }

    func testAppend_KeepsOnlyTheNewestAudioWithinTheDurationCap() {
        // Arrange
        let preRoll = PrimerPreRollBuffer(maximumDuration: 0.5)

        // Act: 1 s of audio in 0.1 s buffers.
        for index in 0..<10 {
            preRoll.append(buffer(frames: 1_600, value: Float(index + 1)), at: Double(index))
        }

        // Assert
        let drained = preRoll.drain()
        XCTAssertEqual(drained.count, 5)
        withExtendedLifetime(drained) {
            XCTAssertEqual(drained.first?.floatChannelData?[0][0], 6)
        }
        XCTAssertEqual(preRoll.bufferedDuration, 0)
    }

    func testAppend_CopiesTheBufferBecauseCoreAudioReusesIt() {
        // Arrange
        let preRoll = PrimerPreRollBuffer(maximumDuration: 1)
        let source = buffer(frames: 160, value: 0.5)

        // Act
        preRoll.append(source, at: 1)
        source.floatChannelData![0][0] = 0.9

        // Assert
        let drained = preRoll.drain()
        withExtendedLifetime(drained) {
            XCTAssertEqual(drained.first?.floatChannelData?[0][0], 0.5)
        }
    }

    func testFirstSignalUptime_SkipsDigitalSilence() {
        // Arrange
        let preRoll = PrimerPreRollBuffer(maximumDuration: 1)

        // Act
        preRoll.append(buffer(frames: 160, value: 0), at: 1)
        preRoll.append(buffer(frames: 160, value: 0.2), at: 2)
        preRoll.append(buffer(frames: 160, value: 0.3), at: 3)

        // Assert
        XCTAssertEqual(preRoll.firstSignalUptime, 2)
    }

    func testStopCollecting_IgnoresALateTapCallback() {
        // Arrange
        let preRoll = PrimerPreRollBuffer(maximumDuration: 1)
        preRoll.append(buffer(frames: 160, value: 0.2), at: 1)

        // Act
        preRoll.stopCollecting()
        preRoll.append(buffer(frames: 160, value: 0.4), at: 2)

        // Assert
        XCTAssertEqual(preRoll.drain().count, 1)
    }
}
