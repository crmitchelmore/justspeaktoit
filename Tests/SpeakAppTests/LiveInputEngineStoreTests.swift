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
        var now: TimeInterval = 100
        var inputDeviceID: UInt32? = 42
        var enginesMade = 0
    }

    private func makeStore(_ environment: Environment, maximumAge: TimeInterval = 5)
        -> LiveInputEngineStore<FakeEngine> {
        LiveInputEngineStore(
            makeEngine: {
                environment.enginesMade += 1
                return FakeEngine()
            },
            primeInput: { $0.inputPrimed = true },
            currentInputDeviceID: { environment.inputDeviceID },
            uptime: { environment.now },
            maximumAge: maximumAge
        )
    }

    func testMakeEngine_HandsOutThePreparedEngineWithItsInputAlreadyBuilt() {
        // Arrange
        let environment = Environment()
        let store = makeStore(environment)
        store.prepare()
        environment.now += 0.3

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
        store.prepare()
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
        store.prepare()
        environment.inputDeviceID = 7

        // Act
        let engine = store.makeEngine()

        // Assert
        XCTAssertFalse(engine.inputPrimed)
        XCTAssertEqual(environment.enginesMade, 2)
    }

    func testMakeEngine_WithAStalePreparation_BuildsAFreshEngine() {
        // Arrange
        let environment = Environment()
        let store = makeStore(environment, maximumAge: 5)
        store.prepare()
        environment.now += 5.1

        // Act
        let engine = store.makeEngine()

        // Assert
        XCTAssertFalse(engine.inputPrimed)
    }

    func testDiscard_DropsAnUnclaimedEngine() {
        // Arrange
        let environment = Environment()
        let store = makeStore(environment)
        store.prepare()

        // Act
        store.discard()

        // Assert
        XCTAssertFalse(store.hasPreparedEngine)
        XCTAssertFalse(store.makeEngine().inputPrimed)
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
    }
}
