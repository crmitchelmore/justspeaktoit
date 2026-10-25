import AppKit
import XCTest

struct CoreJourneyProbeSnapshot: Decodable {
    struct Event: Decodable {
        let stage: String
        let source: String
        let frontmostBundleID: String?
        let uptime: TimeInterval
    }
    let processID: Int32
    let registered: Bool
    let accessibilityTrusted: Bool
    let eventPostingAllowed: Bool
    let states: [String]
    let failureMessage: String?
    let events: [Event]
}

@MainActor
enum CoreJourneyGestureDriver {
    nonisolated static func snapshot(at url: URL) throws -> CoreJourneyProbeSnapshot {
        try JSONDecoder().decode(CoreJourneyProbeSnapshot.self, from: Data(contentsOf: url))
    }

    nonisolated static func wait(
        at url: URL, message: String, matches: @escaping (CoreJourneyProbeSnapshot) -> Bool
    ) {
        let ready = NSPredicate { _, _ in
            guard let snapshot = try? self.snapshot(at: url) else { return false }
            return matches(snapshot)
        }
        XCTAssertEqual(XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 30
        ), .completed, message)
    }

    static func recordAndStop(
        fixture: XCUIApplication, diagnosticsURL: URL, terminalState: String,
        onRecording: () -> Void
    ) throws {
        let offset = try self.snapshot(at: diagnosticsURL).states.count
        fixture.typeKey("k", modifierFlags: [.control, .option, .shift])
        fixture.typeKey("k", modifierFlags: [.control, .option, .shift])
        self.wait(at: diagnosticsURL, message: "Fresh Carbon double-tap must start recording") {
            $0.states.dropFirst(offset).last == "recording"
        }
        onRecording()
        self.wait(at: diagnosticsURL, message: "Recording must survive the production stop-gesture window") {
            guard let lastEvent = $0.events.last else { return false }
            return $0.states.dropFirst(offset).last == "recording"
                && ProcessInfo.processInfo.systemUptime - lastEvent.uptime > 15.2
        }
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                       "com.justspeaktoit.core-journey-fixture")
        fixture.typeKey("k", modifierFlags: [.control, .option, .shift])
        self.wait(at: diagnosticsURL, message: "Fresh recording must reach \(terminalState)") {
            $0.states.dropFirst(offset).last == terminalState
        }
    }
}
