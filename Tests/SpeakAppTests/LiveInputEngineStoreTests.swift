import Foundation
import XCTest

@testable import SpeakApp

/// Regression cover for the ~3 s hot-key → stream-start stall on Bluetooth
/// inputs. The live engine's input node has to be built before the recorder
/// opens the microphone; `LiveInputEngineStore` carries that engine from the
/// start sequencer to whichever live controller the session uses.
final class LiveInputEngineStoreTests: XCTestCase {

    private final class FakeEngine {
        var inputPrimed = false
    }

    private final class Environment {
        var inputDeviceID: UInt32? = 42
        var enginesMade = 0
    }

    private func makeStore(_ environment: Environment) -> LiveInputEngineStore<FakeEngine> {
        LiveInputEngineStore(
            makeEngine: {
                environment.enginesMade += 1
                return FakeEngine()
            },
            primeInput: { $0.inputPrimed = true },
            currentInputDeviceID: { environment.inputDeviceID }
        )
    }

    private func prepared(_ store: LiveInputEngineStore<FakeEngine>) -> LiveInputEngineStore<FakeEngine>.Token {
        let token = store.beginPreparation()
        store.prepare(token)
        return token
    }

    func testMakeEngine_HandsOutThePreparedEngineWithItsInputAlreadyBuilt() {
        // Arrange
        let environment = Environment()
        let store = makeStore(environment)
        _ = prepared(store)

        // Act
        let engine = store.makeEngine()

        // Assert
        XCTAssertTrue(engine.inputPrimed)
        XCTAssertEqual(environment.enginesMade, 1)
        XCTAssertFalse(store.hasPreparedEngine)
    }

    func testMakeEngine_HandsOutAPreparedEngineOnlyOnce() {
        // Arrange
        let environment = Environment()
        let store = makeStore(environment)
        _ = prepared(store)
        let first = store.makeEngine()

        // Act
        let second = store.makeEngine()

        // Assert
        XCTAssertFalse(first === second)
        XCTAssertFalse(second.inputPrimed)
    }

    func testMakeEngine_WithoutPreparation_BuildsAFreshEngine() {
        // Arrange
        let environment = Environment()
        let store = makeStore(environment)

        // Act
        let engine = store.makeEngine()

        // Assert
        XCTAssertFalse(engine.inputPrimed)
        XCTAssertEqual(environment.enginesMade, 1)
    }

    func testMakeEngine_AfterTheInputDeviceChanged_BuildsAFreshEngine() {
        // Arrange: a prepared input node stays bound to the device it was built
        // against, so handing it over after a route change would capture from
        // the wrong microphone.
        let environment = Environment()
        let store = makeStore(environment)
        _ = prepared(store)
        environment.inputDeviceID = 7

        // Act
        let engine = store.makeEngine()

        // Assert
        XCTAssertFalse(engine.inputPrimed)
        XCTAssertEqual(environment.enginesMade, 2)
    }

    func testMakeEngine_WhenTheInputDeviceIsUnknown_NeverReusesThePreparedEngine() {
        // Arrange: two failed device lookups are not evidence of the same device.
        let environment = Environment()
        environment.inputDeviceID = nil
        let store = makeStore(environment)
        _ = prepared(store)

        // Act
        let engine = store.makeEngine()

        // Assert
        XCTAssertFalse(engine.inputPrimed)
        XCTAssertFalse(store.hasPreparedEngine)
    }

    func testMakeEngine_WhenTheDeviceBecomesUnknownAfterPreparation_BuildsAFreshEngine() {
        // Arrange
        let environment = Environment()
        let store = makeStore(environment)
        _ = prepared(store)
        environment.inputDeviceID = nil

        // Act
        let engine = store.makeEngine()

        // Assert
        XCTAssertFalse(engine.inputPrimed)
    }

    func testMakeEngine_AfterASlowColdModelLoad_StillHandsOutThePreparedEngine() {
        // Arrange: FluidAudio and sherpa-onnx claim the engine only after their
        // model has loaded, which can take many seconds on a cold start. The
        // store has no clock: the preparation stays valid until its start ends.
        let environment = Environment()
        let store = makeStore(environment)
        _ = prepared(store)
        _ = store.hasPreparedEngine // other starts' work must not expire it either

        // Act
        let engine = store.makeEngine()

        // Assert
        XCTAssertTrue(engine.inputPrimed)
    }

    func testPrepare_WithAStaleToken_DoesNotInstallItsEngine() {
        // Arrange: an abandoned start's input-node build finishes after a newer
        // start has already prepared its own engine.
        let environment = Environment()
        let store = makeStore(environment)
        let stale = store.beginPreparation()
        let current = prepared(store)

        // Act
        store.prepare(stale)
        let engine = store.makeEngine()

        // Assert
        XCTAssertTrue(engine.inputPrimed)
        XCTAssertEqual(environment.enginesMade, 2)
        store.discard(current)
    }

    func testPrepare_WithAStaleTokenAndNoNewerEngine_LeavesTheStoreEmpty() {
        // Arrange
        let environment = Environment()
        let store = makeStore(environment)
        let stale = store.beginPreparation()
        _ = store.beginPreparation()

        // Act
        store.prepare(stale)

        // Assert
        XCTAssertFalse(store.hasPreparedEngine)
    }

    func testDiscard_DropsAnUnclaimedEngine() {
        // Arrange
        let environment = Environment()
        let store = makeStore(environment)
        let token = prepared(store)

        // Act
        store.discard(token)

        // Assert
        XCTAssertFalse(store.hasPreparedEngine)
        XCTAssertFalse(store.makeEngine().inputPrimed)
    }

    func testDiscard_WithAStaleToken_KeepsTheCurrentPreparation() {
        // Arrange: the abandoned start finishes after its replacement prepared.
        let environment = Environment()
        let store = makeStore(environment)
        let stale = prepared(store)
        _ = prepared(store)

        // Act
        store.discard(stale)

        // Assert
        XCTAssertTrue(store.hasPreparedEngine)
        XCTAssertTrue(store.makeEngine().inputPrimed)
    }

    func testRestore_AfterAFailedStart_HandsTheEngineToTheFallbackController() {
        // Arrange: SpeechAnalyzer claimed the prepared engine, then failed; the
        // legacy Apple Speech fallback starts beside the running recorder.
        let environment = Environment()
        let store = makeStore(environment)
        _ = prepared(store)
        let failed = store.makeEngine()

        // Act
        store.restore(failed)
        let fallback = store.makeEngine()

        // Assert
        XCTAssertTrue(fallback === failed)
        XCTAssertEqual(environment.enginesMade, 1)
    }

    func testRestore_AfterThePreparationEnded_IsIgnored() {
        // Arrange
        let environment = Environment()
        let store = makeStore(environment)
        let token = prepared(store)
        let claimed = store.makeEngine()
        store.discard(token)

        // Act
        store.restore(claimed)

        // Assert
        XCTAssertFalse(store.hasPreparedEngine)
    }

    func testRestore_OfAnEngineTheStoreDidNotPrepare_IsIgnored() {
        // Arrange
        let environment = Environment()
        let store = makeStore(environment)
        _ = prepared(store)
        _ = store.makeEngine()

        // Act
        store.restore(FakeEngine())

        // Assert
        XCTAssertFalse(store.hasPreparedEngine)
    }
}

/// Source guard for the same stall: a live controller that builds its own
/// `AVAudioEngine()` at start bypasses the prepared engine and brings the
/// ~3 s Bluetooth stall back.
final class LiveInputEngineSourceGuardTests: XCTestCase {

    private var appSources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/SpeakApp")
    }

    private func source(_ name: String) throws -> String {
        try String(contentsOf: appSources.appendingPathComponent(name), encoding: .utf8)
    }

    func testLiveControllers_TakeTheirEngineFromThePreparedStore() throws {
        // Arrange
        let names = try FileManager.default.contentsOfDirectory(atPath: appSources.path)
        let liveCaptureFiles = names.filter { $0.hasSuffix("LiveController.swift") }
            + ["NativeOSXLiveTranscriber.swift", "FluidAudioLiveSupport.swift"]
        XCTAssertGreaterThan(liveCaptureFiles.count, 10)

        for name in liveCaptureFiles {
            // Act: a stored-property default is replaced before every start, so
            // only engines built inside a code path matter.
            let offending = try source(name)
                .components(separatedBy: .newlines)
                .filter { $0.contains("AVAudioEngine()") }
                .filter { line in
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    return !(trimmed.hasPrefix("private var ") || trimmed.hasPrefix("var "))
                }

            // Assert
            XCTAssertEqual(
                offending,
                [],
                "\(name) builds its own AVAudioEngine; use LiveInputEngines.shared.makeEngine()"
            )
        }
    }

    func testRecordStart_PreparesTheLiveInputBeforeCapture() throws {
        // Act
        let text = try source("MainManager.swift")

        // Assert
        XCTAssertTrue(text.contains("prepareStream: prepareStream"))
        XCTAssertTrue(text.contains("liveInputPreparation.prepare()"))
        XCTAssertTrue(text.contains("transcriptionManager.liveRouteUsesLiveInputEngine"))
    }

    func testSpeechAnalyzerStartFailure_ReturnsItsEngineForTheFallback() throws {
        // Act
        let text = try source("AppleSpeechAnalyzerLiveController.swift")

        // Assert
        XCTAssertTrue(text.contains("LiveInputEngines.shared.restore(audioEngine)"))
    }
}
