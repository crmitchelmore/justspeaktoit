import Foundation
import XCTest

extension XCUIApplication {
    /// Fresh owned simulators may present onboarding after the root appears.
    /// Exercise its real Skip control without granting access or starting audio.
    func skipFirstRunForUITest(ready element: XCUIElement) throws {
        let facts = LaunchReadinessFacts()
        let finish = buttons["firstRunFinishButton"]
        let appeared = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            facts.reset([.initialReadyExists, .initialFinishExists])
            return facts.observe(.initialReadyExists, element.exists)
                || facts.observe(.initialFinishExists, finish.exists)
        }, object: nil)
        let appearedResult = XCTWaiter.wait(for: [appeared], timeout: 60)
        facts.record(appearedResult, field: .initialWaitResult)
        guard appearedResult == .completed else {
            facts.emitFailure(.initialAppearance)
            XCTFail("Neither the app's root nor its onboarding appeared")
            throw AppLaunchTimeout()
        }
        // Allow the root's asynchronous onboarding presentation to arrive even
        // when its underlying Settings/record control already exists.
        let finishAppeared = finish.waitForExistence(timeout: 15)
        facts.observe(.finishWaitObserved, finishAppeared)
        if finishAppeared {
            guard facts.observe(.finishLabelMatchesSkip, finish.label == "Skip"),
                  facts.observe(.finishEnabled, finish.isEnabled),
                  facts.observe(.finishHittable, finish.isHittable) else {
                facts.emitFailure(.idleSkip)
                XCTFail("Expected the actual idle onboarding Skip control")
                throw AppLaunchTimeout()
            }
            facts.observe(.skipAttempted, true)
            finish.tap()
        }
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            facts.reset([.finishExists, .readyExists, .readyHittable])
            return !facts.observe(.finishExists, finish.exists)
                && facts.observe(.readyExists, element.exists)
                && facts.observe(.readyHittable, element.isHittable)
        }, object: nil)
        let readyResult = XCTWaiter.wait(for: [ready], timeout: 15)
        facts.record(readyResult, field: .finalWaitResult)
        guard readyResult == .completed else {
            facts.emitFailure(.finalReady)
            XCTFail("The app's root control was not reachable after the first-run check")
            throw AppLaunchTimeout()
        }
    }
}

private struct AppLaunchTimeout: Error {}

/// Records only observations made by the existing readiness checks. No new AX queries.
private final class LaunchReadinessFacts: @unchecked Sendable {
    enum Field: String, CaseIterable {
        case initialReadyExists, initialFinishExists, initialWaitResult
        case finishWaitObserved, finishLabelMatchesSkip, finishEnabled, finishHittable, skipAttempted
        case finishExists, readyExists, readyHittable, finalWaitResult
    }

    enum FailureStage: String {
        case initialAppearance, idleSkip, finalReady
    }

    private let lock = NSLock()
    private var values: [Field: Any] = Dictionary(uniqueKeysWithValues: Field.allCases.map { ($0, NSNull()) })
    private var emitted = false

    init() {
        self.values[.skipAttempted] = false
    }

    func reset(_ fields: [Field]) {
        self.lock.withLock {
            for field in fields { self.values[field] = NSNull() }
        }
    }

    @discardableResult
    func observe(_ field: Field, _ value: Bool) -> Bool {
        self.lock.withLock { self.values[field] = value }
        return value
    }

    func record(_ result: XCTWaiter.Result, field: Field) {
        let value: String
        switch result {
        case .completed: value = "completed"
        case .timedOut: value = "timedOut"
        case .incorrectOrder: value = "incorrectOrder"
        case .invertedFulfillment: value = "invertedFulfillment"
        case .interrupted: value = "interrupted"
        @unknown default: value = "unknown"
        }
        self.lock.withLock { self.values[field] = value }
    }

    func emitFailure(_ stage: FailureStage) {
        let snapshot: [String: Any]? = self.lock.withLock { () -> [String: Any]? in
            guard !self.emitted else { return nil }
            self.emitted = true
            var snapshot = Dictionary(uniqueKeysWithValues: self.values.map { ($0.key.rawValue, $0.value) })
            snapshot["stage"] = stage.rawValue
            return snapshot
        }
        guard let snapshot,
              let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys]) else {
            return
        }
        var line = Data("jsti-ui-launch-readiness: ".utf8)
        line.append(data)
        line.append(0x0A)
        try? FileHandle.standardError.write(contentsOf: line)
    }
}
