#if os(macOS)
import XCTest

@testable import SpeakHotKeys

/// Raw press edges let the host warm capture before a gesture is known. They
/// must arrive in order, ahead of the gesture for the same edge, and must not
/// change which gestures fire.
@MainActor
final class GesturePressEdgeTests: XCTestCase {
    private let configuration = HotKeyConfiguration(holdThreshold: 0.02, doubleTapWindow: 0.05)

    func testPress_reportsDownBeforeTheHoldStarts() async {
        let log = EdgeLog()
        let detector = makeDetector(log: log)

        detector.keyDown(source: "test")
        XCTAssertEqual(log.entries, ["pressed"])
        await log.waitFor("holdStart", in: self)
        detector.keyUp(source: "test")

        XCTAssertEqual(log.entries, ["pressed", "holdStart", "released", "holdEnd"])
    }

    func testDoubleTap_reportsTheSecondUpBeforeTheDoubleTap() {
        let log = EdgeLog()
        let detector = makeDetector(log: log)

        detector.keyDown(source: "test")
        detector.keyUp(source: "test")
        detector.keyDown(source: "test")
        detector.keyUp(source: "test")

        XCTAssertEqual(log.entries, ["pressed", "released", "pressed", "released", "doubleTap"])
    }

    func testRepeatedKeyDown_reportsOneDown() {
        let log = EdgeLog()
        let detector = makeDetector(log: log)

        detector.keyDown(source: "test")
        detector.keyDown(source: "test")
        detector.keyUp(source: "test")
        detector.keyUp(source: "test")

        XCTAssertEqual(log.entries, ["pressed", "released"])
    }

    func testReset_reportsAResetEdgeBeforeTheBalancedHoldEnd() async {
        let log = EdgeLog()
        let detector = makeDetector(log: log)

        detector.keyDown(source: "test")
        await log.waitFor("holdStart", in: self)
        detector.reset()

        XCTAssertEqual(log.entries, ["pressed", "holdStart", "reset", "holdEnd"])
    }

    func testDownEdge_carriesAMonotonicTime() {
        var received: [HotKeyPressEvent] = []
        let detector = GestureDetector(configuration: configuration)
        detector.onPress = { received.append($0) }
        let before = ProcessInfo.processInfo.systemUptime

        detector.keyDown(source: "carbon")
        detector.keyUp(source: "carbon")

        XCTAssertEqual(received.map(\.phase), [.pressed, .released])
        XCTAssertEqual(received.first?.source, "carbon")
        XCTAssertGreaterThanOrEqual(received.first?.uptime ?? 0, before)
        XCTAssertGreaterThanOrEqual(received.last?.uptime ?? 0, received.first?.uptime ?? .infinity)
    }

    func testEngine_deliversPressEdgesUntilUnregistered() {
        let engine = HotKeyEngine(configuration: configuration)
        var phases: [HotKeyPressPhase] = []
        let token = engine.registerPress { phases.append($0.phase) }

        engine.gestureDetector.keyDown(source: "test")
        engine.gestureDetector.keyUp(source: "test")
        engine.unregister(token)
        engine.gestureDetector.keyDown(source: "test")

        XCTAssertEqual(phases, [.pressed, .released])
        engine.stop()
    }

    private func makeDetector(log: EdgeLog) -> GestureDetector {
        let detector = GestureDetector(configuration: configuration)
        detector.onGesture = { log.record($0.gesture.rawValue) }
        detector.onPress = { log.record($0.phase.rawValue) }
        return detector
    }
}

@MainActor
private final class EdgeLog {
    private(set) var entries: [String] = []
    private var waiting: (name: String, expectation: XCTestExpectation)?

    func record(_ entry: String) {
        entries.append(entry)
        if let waiting, waiting.name == entry {
            waiting.expectation.fulfill()
            self.waiting = nil
        }
    }

    func waitFor(_ entry: String, in testCase: XCTestCase) async {
        guard !entries.contains(entry) else { return }
        let expectation = testCase.expectation(description: entry)
        waiting = (entry, expectation)
        await testCase.fulfillment(of: [expectation], timeout: 1)
    }
}
#endif
