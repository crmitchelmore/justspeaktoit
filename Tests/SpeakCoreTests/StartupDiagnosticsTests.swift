import XCTest
@testable import SpeakCore

// One suite covering one type's whole contract; splitting it by checkpoint
// would hide which invariants are proven together.
// swiftlint:disable type_body_length

/// Local iOS startup-boundary diagnostics (issue #972).
///
/// Every test drives the recorder through an injected clock and an injected
/// line sink, so each checkpoint is proven to measure the boundary it names —
/// not a boundary nearby, and not a fabricated one.
final class StartupDiagnosticsTests: XCTestCase {
    /// Injected clock and sink. `@unchecked Sendable` because the recorder's
    /// closures are `@Sendable` and every test drives it from one thread.
    private final class Harness: @unchecked Sendable {
        private let lock = NSLock()
        private var _now = Date(timeIntervalSince1970: 1_000)
        private var _lines: [String] = []

        var now: Date {
            lock.lock(); defer { lock.unlock() }
            return _now
        }

        var lines: [String] {
            lock.lock(); defer { lock.unlock() }
            return _lines
        }

        /// Advances the clock by whole milliseconds.
        func advance(milliseconds: Int) {
            lock.lock(); defer { lock.unlock() }
            _now = _now.addingTimeInterval(Double(milliseconds) / 1000)
        }

        func makeDiagnostics() -> StartupDiagnostics {
            StartupDiagnostics(
                now: { [self] in now },
                emit: { [self] line in
                    lock.lock(); defer { lock.unlock() }
                    _lines.append(line)
                }
            )
        }
    }

    private func fields(of line: String) -> [String: String] {
        var parsed: [String: String] = [:]
        for token in line.split(separator: " ").dropFirst() {
            let parts = token.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            parsed[String(parts[0])] = String(parts[1])
        }
        return parsed
    }

    // MARK: - Each checkpoint measures its own boundary

    func testEachCheckpointMeasuresItsOwnBoundary() {
        let harness = Harness()
        var diagnostics = harness.makeDiagnostics()
        let run = UUID()
        diagnostics.begin(run: run, entry: nil, localOrigin: .service)

        harness.advance(milliseconds: 40)
        diagnostics.note(.stage(.credentialsReady), run: run)
        harness.advance(milliseconds: 60)
        diagnostics.note(.stage(.audioSessionConfigured), run: run)
        harness.advance(milliseconds: 100)
        diagnostics.note(.stage(.engineStarted), run: run)
        harness.advance(milliseconds: 15)
        diagnostics.note(.backend(.appleAnalyzer), run: run)
        diagnostics.note(.stage(.sessionStarted), run: run)
        diagnostics.finish(.started, run: run)

        XCTAssertEqual(harness.lines.count, 1)
        let parsed = fields(of: harness.lines[0])
        XCTAssertEqual(parsed["credentials-ms"], "40")
        XCTAssertEqual(parsed["audio-session-ms"], "100")
        XCTAssertEqual(parsed["engine-start-ms"], "200")
        XCTAssertEqual(parsed["session-start-ms"], "215")
        XCTAssertEqual(parsed["backend"], "appleAnalyzer")
        XCTAssertEqual(parsed["outcome"], "started")
        XCTAssertEqual(parsed["origin"], "service")
        XCTAssertEqual(parsed["entry"], "local")
    }

    /// The entry an upstream surface observed must survive every awaited
    /// helper below it, so the measured startup covers the whole hop.
    func testUpstreamEntryIsPreservedAcrossAwaitedHelpers() {
        let harness = Harness()
        var diagnostics = harness.makeDiagnostics()
        let run = UUID()
        let performEntry = StartupEntry(origin: .toggleIntent, observedAt: harness.now)

        // Time passes in helpers between `perform()` entry and `begin`.
        harness.advance(milliseconds: 250)
        diagnostics.begin(run: run, entry: performEntry, localOrigin: .service)
        harness.advance(milliseconds: 50)
        diagnostics.note(.stage(.credentialsReady), run: run)
        diagnostics.finish(.started, run: run)

        let parsed = fields(of: harness.lines[0])
        XCTAssertEqual(parsed["origin"], "toggleIntent")
        XCTAssertEqual(parsed["entry"], "upstream")
        // 250 ms of helper time plus 50 ms of credential wait.
        XCTAssertEqual(parsed["credentials-ms"], "300")
    }

    // MARK: - Missing stages stay missing

    func testFailedStartOmitsUnreachedStagesAndNeverZeroesThem() {
        let harness = Harness()
        var diagnostics = harness.makeDiagnostics()
        let run = UUID()
        diagnostics.begin(run: run, entry: nil, localOrigin: .service)
        harness.advance(milliseconds: 30)
        diagnostics.note(.stage(.credentialsReady), run: run)
        harness.advance(milliseconds: 20)
        diagnostics.note(.stage(.audioSessionConfigured), run: run)
        diagnostics.finish(.failed, run: run)

        let line = harness.lines[0]
        let parsed = fields(of: line)
        XCTAssertEqual(parsed["outcome"], "failed")
        XCTAssertEqual(parsed["credentials-ms"], "30")
        XCTAssertEqual(parsed["audio-session-ms"], "50")
        XCTAssertNil(parsed["engine-start-ms"])
        XCTAssertNil(parsed["session-start-ms"])
        XCTAssertNil(parsed["first-partial-ms"])
        XCTAssertFalse(line.contains("engine-start"))
    }

    func testCancelledStartKeepsThePartialTimelineItDidReach() {
        let harness = Harness()
        var diagnostics = harness.makeDiagnostics()
        let run = UUID()
        diagnostics.begin(run: run, entry: nil, localOrigin: .service)
        harness.advance(milliseconds: 12)
        diagnostics.note(.stage(.credentialsReady), run: run)
        diagnostics.finish(.cancelled, run: run)

        let parsed = fields(of: harness.lines[0])
        XCTAssertEqual(parsed["outcome"], "cancelled")
        XCTAssertEqual(parsed["credentials-ms"], "12")
        XCTAssertEqual(parsed["backend"], "unresolved")
    }

    /// A backend that never resolved is reported as unresolved, never as the
    /// backend the start meant to use.
    func testUnresolvedBackendIsNotGuessed() {
        let harness = Harness()
        var diagnostics = harness.makeDiagnostics()
        let run = UUID()
        diagnostics.begin(run: run, entry: nil, localOrigin: .coordinator)
        diagnostics.finish(.failed, run: run)
        XCTAssertEqual(fields(of: harness.lines[0])["backend"], "unresolved")
    }

    /// The Apple path refines from the analyzer to the legacy recogniser; the
    /// branch that actually ran is the one reported.
    func testBackendRefinementReportsTheBranchThatActuallyRan() {
        let harness = Harness()
        var diagnostics = harness.makeDiagnostics()
        let run = UUID()
        diagnostics.begin(run: run, entry: nil, localOrigin: .service)
        diagnostics.note(.backend(.appleAnalyzer), run: run)
        diagnostics.note(.backend(.appleLegacy), run: run)
        diagnostics.finish(.started, run: run)
        XCTAssertEqual(fields(of: harness.lines[0])["backend"], "appleLegacy")
    }

    // MARK: - First partial

    func testFirstPartialIsRecordedOnceAndEmittedAsOneLaterLine() {
        let harness = Harness()
        var diagnostics = harness.makeDiagnostics()
        let run = UUID()
        diagnostics.begin(run: run, entry: nil, localOrigin: .service)
        harness.advance(milliseconds: 100)
        diagnostics.note(.stage(.sessionStarted), run: run)
        diagnostics.note(.backend(.openAIRealtime), run: run)
        diagnostics.finish(.started, run: run)
        XCTAssertEqual(harness.lines.count, 1)

        harness.advance(milliseconds: 1_500)
        diagnostics.noteFirstPartial(run: run)
        harness.advance(milliseconds: 40)
        diagnostics.noteFirstPartial(run: run)
        diagnostics.note(.stage(.firstPartial), run: run)

        XCTAssertEqual(harness.lines.count, 2)
        XCTAssertTrue(harness.lines[1].hasPrefix("startup-partial "))
        let parsed = fields(of: harness.lines[1])
        XCTAssertEqual(parsed["first-partial-ms"], "1600")
        XCTAssertEqual(parsed["backend"], "openAIRealtime")
    }

    /// A partial that beats the summary belongs in the summary, and still only
    /// produces one observation.
    func testPartialBeforeTheSummaryIsFoldedIntoIt() {
        let harness = Harness()
        var diagnostics = harness.makeDiagnostics()
        let run = UUID()
        diagnostics.begin(run: run, entry: nil, localOrigin: .service)
        harness.advance(milliseconds: 90)
        diagnostics.noteFirstPartial(run: run)
        harness.advance(milliseconds: 10)
        diagnostics.note(.stage(.sessionStarted), run: run)
        diagnostics.finish(.started, run: run)

        XCTAssertEqual(harness.lines.count, 1)
        XCTAssertEqual(fields(of: harness.lines[0])["first-partial-ms"], "90")
    }

    /// Batch has no live partial at all, so its timeline simply ends earlier.
    func testBatchTimelineHasNoFirstPartialField() {
        let harness = Harness()
        var diagnostics = harness.makeDiagnostics()
        let run = UUID()
        diagnostics.begin(run: run, entry: nil, localOrigin: .service)
        diagnostics.note(.backend(.batch), run: run)
        harness.advance(milliseconds: 70)
        diagnostics.note(.stage(.engineStarted), run: run)
        diagnostics.note(.stage(.sessionStarted), run: run)
        diagnostics.finish(.started, run: run)

        XCTAssertEqual(harness.lines.count, 1)
        XCTAssertFalse(harness.lines[0].contains("first-partial"))
        XCTAssertEqual(fields(of: harness.lines[0])["backend"], "batch")
    }

    // MARK: - Run identity

    func testLateCallbackCannotAttachToAReplacementRun() {
        let harness = Harness()
        var diagnostics = harness.makeDiagnostics()
        let retired = UUID()
        let replacement = UUID()
        diagnostics.begin(run: retired, entry: nil, localOrigin: .service)
        harness.advance(milliseconds: 10)
        diagnostics.begin(run: replacement, entry: nil, localOrigin: .service)

        // The retired run's backend callback lands after its replacement began.
        diagnostics.note(.stage(.engineStarted), run: retired)
        diagnostics.note(.backend(.sharedClient), run: retired)
        diagnostics.noteFirstPartial(run: retired)
        harness.advance(milliseconds: 25)
        diagnostics.note(.stage(.sessionStarted), run: replacement)
        diagnostics.finish(.started, run: replacement)

        let parsed = fields(of: harness.lines[0])
        XCTAssertEqual(parsed["session-start-ms"], "25")
        XCTAssertNil(parsed["engine-start-ms"])
        XCTAssertNil(parsed["first-partial-ms"])
        XCTAssertEqual(parsed["backend"], "unresolved")
    }

    /// A duplicate start that the lifecycle refuses never reaches the engine,
    /// so no engine-start event may appear for it.
    func testDuplicateStartDoesNotFabricateAnEngineStartEvent() {
        let harness = Harness()
        var diagnostics = harness.makeDiagnostics()
        let first = UUID()
        diagnostics.begin(run: first, entry: nil, localOrigin: .service)
        harness.advance(milliseconds: 30)
        diagnostics.note(.stage(.engineStarted), run: first)
        diagnostics.note(.stage(.sessionStarted), run: first)
        diagnostics.finish(.started, run: first)

        // A second, refused start: it has its own identity and never ran.
        let duplicate = UUID()
        diagnostics.begin(run: duplicate, entry: nil, localOrigin: .service)
        diagnostics.finish(.cancelled, run: duplicate)

        XCTAssertEqual(harness.lines.count, 2)
        XCTAssertTrue(harness.lines[0].contains("engine-start-ms=30"))
        XCTAssertFalse(harness.lines[1].contains("engine-start"))
        XCTAssertTrue(harness.lines[1].contains("outcome=cancelled"))
    }

    func testRetiredRunAcceptsNothingFurther() {
        let harness = Harness()
        var diagnostics = harness.makeDiagnostics()
        let run = UUID()
        diagnostics.begin(run: run, entry: nil, localOrigin: .service)
        diagnostics.finish(.started, run: run)
        diagnostics.retire()
        diagnostics.noteFirstPartial(run: run)
        diagnostics.note(.stage(.engineStarted), run: run)
        diagnostics.finish(.failed, run: run)
        XCTAssertEqual(harness.lines.count, 1)
    }

    func testOnlyOneSummaryIsEmittedPerRun() {
        let harness = Harness()
        var diagnostics = harness.makeDiagnostics()
        let run = UUID()
        diagnostics.begin(run: run, entry: nil, localOrigin: .service)
        diagnostics.finish(.started, run: run)
        diagnostics.finish(.failed, run: run)
        diagnostics.finish(.cancelled, run: run)
        XCTAssertEqual(harness.lines.count, 1)
        XCTAssertTrue(harness.lines[0].contains("outcome=started"))
    }

    // MARK: - Wall-clock contract

    /// Wall-clock helpers make negative intervals possible; the contract turns
    /// them into an absent field rather than a bogus number. No monotonic
    /// precision is claimed anywhere.
    func testNegativeIntervalIsReportedAsAbsentNotAsANumber() {
        var timeline = StartupTimeline(
            run: UUID(),
            origin: .service,
            entryAt: Date(timeIntervalSince1970: 2_000),
            entryIsUpstream: false
        )
        timeline.mark(.credentialsReady, at: Date(timeIntervalSince1970: 1_999))
        XCTAssertNil(timeline.offsetMilliseconds(of: .credentialsReady))
        XCTAssertFalse(timeline.summaryLine(outcome: .started).contains("credentials-ms"))
    }

    func testAStageIsMeasuredOnceSoARepeatCallbackCannotMoveIt() {
        var timeline = StartupTimeline(
            run: UUID(),
            origin: .service,
            entryAt: Date(timeIntervalSince1970: 0),
            entryIsUpstream: false
        )
        XCTAssertTrue(timeline.mark(.engineStarted, at: Date(timeIntervalSince1970: 0.5)))
        XCTAssertFalse(timeline.mark(.engineStarted, at: Date(timeIntervalSince1970: 9)))
        XCTAssertEqual(timeline.offsetMilliseconds(of: .engineStarted), 500)
    }
}

// swiftlint:enable type_body_length
