import Foundation
import XCTest

@testable import SpeakApp

/// A live controller claims the key-down primer's engine *while it is already
/// running*. If that controller throws before it owns the engine (recognizer
/// unavailable, unusable input format), nothing else stops it: the microphone
/// stays open and the next press builds an input node beside it. A failed or
/// abandoned start therefore releases the claimed adopted engine.
final class LiveInputEngineStoreFailedStartTests: XCTestCase {

    private final class FakeEngine {
        var isRunning = true
    }

    private final class Environment {
        var inputDeviceID: UInt32? = 42
        var released: [FakeEngine] = []

        lazy var hooks = LiveInputEngineStore<FakeEngine>.AdoptionHooks(
            willHandOut: { _ in },
            release: { [unowned self] engine in
                engine.isRunning = false
                self.released.append(engine)
            }
        )
    }

    private func makeStore(_ environment: Environment) -> LiveInputEngineStore<FakeEngine> {
        LiveInputEngineStore(
            makeEngine: { FakeEngine() },
            primeInput: { _ in },
            currentInputDeviceID: { environment.inputDeviceID }
        )
    }

    /// Stands in for `NativeOSXLiveTranscriber` / `FluidAudioEngineCapture`
    /// failing after `makeEngine()` without stopping what it was handed.
    private func failingControllerStart(_ store: LiveInputEngineStore<FakeEngine>) throws {
        _ = store.makeEngine()
        throw TranscriptionManagerError.noUsableAudioInput
    }

    func testDiscard_AfterAControllerThrewHoldingTheAdoptedEngine_StopsIt() {
        // Arrange
        let environment = Environment()
        let store = makeStore(environment)
        let token = store.beginPreparation()
        let primed = FakeEngine()
        store.adopt(primed, inputDeviceID: 42, token: token, hooks: environment.hooks)
        XCTAssertThrowsError(try failingControllerStart(store))

        // Act
        store.discard(token, releasingClaimed: true)

        // Assert
        XCTAssertFalse(primed.isRunning)
        XCTAssertEqual(environment.released.count, 1)
    }

    func testDiscard_AfterASuccessfulStart_LeavesTheClaimedEngineRunning() {
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

    func testDiscard_ReleasingClaimed_WithAStaleToken_LeavesTheNewerStartsEngineRunning() {
        // Arrange
        let environment = Environment()
        let store = makeStore(environment)
        let stale = store.beginPreparation()
        let current = store.beginPreparation()
        let primed = FakeEngine()
        store.adopt(primed, inputDeviceID: 42, token: current, hooks: environment.hooks)
        _ = store.makeEngine()

        // Act
        store.discard(stale, releasingClaimed: true)

        // Assert
        XCTAssertTrue(primed.isRunning)
        XCTAssertTrue(environment.released.isEmpty)
    }

    func testDiscard_ReleasingClaimed_IgnoresABuiltEngineTheStoreDoesNotOwn() {
        // Arrange
        let environment = Environment()
        let store = makeStore(environment)
        let token = store.beginPreparation()
        store.prepare(token)
        let built = store.makeEngine()

        // Act
        store.discard(token, releasingClaimed: true)

        // Assert
        XCTAssertTrue(built.isRunning)
        XCTAssertTrue(environment.released.isEmpty)
    }

    func testDiscard_AfterTheFallbackControllerAlsoFailed_StopsTheRestoredEngineOnce() {
        // Arrange: the analyzer fails and restores the engine; the legacy
        // fallback claims it again and fails too.
        let environment = Environment()
        let store = makeStore(environment)
        let token = store.beginPreparation()
        let primed = FakeEngine()
        store.adopt(primed, inputDeviceID: 42, token: token, hooks: environment.hooks)
        store.restore(store.makeEngine())
        XCTAssertThrowsError(try failingControllerStart(store))

        // Act
        store.discard(token, releasingClaimed: true)
        store.discard(token, releasingClaimed: true)

        // Assert
        XCTAssertFalse(primed.isRunning)
        XCTAssertEqual(environment.released.count, 1)
    }
}
