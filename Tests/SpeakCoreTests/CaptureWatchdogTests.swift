import Foundation
@testable import SpeakCore
import XCTest

/// The bounds for issue #993. The iOS wiring cannot run on the host, so every
/// rule about *when* a watchdog fires — and, more importantly, when it must
/// not — lives here where `swift test` executes it against an explicit clock
/// rather than by waiting.
final class CaptureWatchdogTests: XCTestCase {
    private let budget = CaptureWatchdogBudget(
        startDeadline: 60,
        firstInputDeadline: 10,
        maximumDuration: 3600,
        maximumDurationWarningLead: 300
    )

    // MARK: - Nothing fires during a healthy capture

    func testHealthyCaptureNeverTrips() {
        var monitor = CaptureWatchdogMonitor(budget)
        monitor.note(.credentialsReady, atSeconds: 0.1)
        monitor.note(.audioSessionConfigured, atSeconds: 0.2)
        monitor.note(.engineStarted, atSeconds: 0.3)
        monitor.note(.sessionStarted, atSeconds: 0.5)
        monitor.noteInputObserved()
        for tick in stride(from: 1.0, through: 3000, by: 1) {
            XCTAssertNil(monitor.evaluate(atSeconds: tick), "tripped at \(tick)s")
        }
    }

    /// A user who says nothing for the first half-minute is normal. Their tap
    /// is delivering buffers of silence the whole time, so the no-audio
    /// detector — which counts buffers, not levels — has nothing to fire on.
    func testQuietStartDoesNotTripTheNoAudioDetector() {
        var monitor = CaptureWatchdogMonitor(budget)
        monitor.note(.engineStarted, atSeconds: 0.3)
        monitor.noteInputObserved()
        monitor.note(.sessionStarted, atSeconds: 0.5)
        for tick in stride(from: 1.0, through: 30, by: 0.5) {
            XCTAssertNil(monitor.evaluate(atSeconds: tick))
        }
    }

    /// A slow-but-progressing start is not a stalled one, right up to the
    /// deadline.
    func testStartDeadlineDoesNotFireEarly() {
        var monitor = CaptureWatchdogMonitor(budget)
        monitor.note(.credentialsReady, atSeconds: 12)
        monitor.note(.audioSessionConfigured, atSeconds: 30)
        XCTAssertNil(monitor.evaluate(atSeconds: 59.9))
    }

    // MARK: - Start deadline

    func testStartDeadlineFiresNamingTheLastStageCrossed() {
        var monitor = CaptureWatchdogMonitor(budget)
        monitor.note(.credentialsReady, atSeconds: 1)
        monitor.note(.audioSessionConfigured, atSeconds: 2)
        XCTAssertEqual(
            monitor.evaluate(atSeconds: 60),
            .startStalled(after: .audioSessionConfigured)
        )
    }

    func testStartDeadlineReportsNoBoundaryWhenNoneWasCrossed() {
        var monitor = CaptureWatchdogMonitor(budget)
        XCTAssertEqual(monitor.evaluate(atSeconds: 61), .startStalled(after: nil))
    }

    func testStartDeadlineIsClosedOnceTheBackendStarted() {
        var monitor = CaptureWatchdogMonitor(budget)
        monitor.note(.engineStarted, atSeconds: 1)
        monitor.noteInputObserved()
        monitor.note(.sessionStarted, atSeconds: 2)
        XCTAssertNil(monitor.evaluate(atSeconds: 600))
    }

    // MARK: - No-audio detector

    func testNoAudioFiresWhenTheTapDeliveredNothing() {
        var monitor = CaptureWatchdogMonitor(budget)
        monitor.note(.engineStarted, atSeconds: 2)
        monitor.note(.sessionStarted, atSeconds: 2.5)
        XCTAssertNil(monitor.evaluate(atSeconds: 11.9))
        XCTAssertEqual(monitor.evaluate(atSeconds: 12), .noInput)
    }

    /// It counts from the engine, not from the press: a start that spent
    /// twenty seconds on credentials has not had a microphone for twenty
    /// seconds.
    func testNoAudioIsMeasuredFromEngineStart() {
        var monitor = CaptureWatchdogMonitor(budget)
        monitor.note(.credentialsReady, atSeconds: 20)
        monitor.note(.engineStarted, atSeconds: 25)
        XCTAssertNil(monitor.evaluate(atSeconds: 30))
        XCTAssertEqual(monitor.evaluate(atSeconds: 35), .noInput)
    }

    /// Without an engine there is no tap to have failed, so the start deadline
    /// owns that case and the no-audio detector stays silent.
    func testNoAudioNeverFiresWithoutAnEngine() {
        var monitor = CaptureWatchdogMonitor(budget)
        monitor.note(.credentialsReady, atSeconds: 1)
        XCTAssertNil(monitor.evaluate(atSeconds: 40))
        XCTAssertEqual(monitor.evaluate(atSeconds: 60), .startStalled(after: .credentialsReady))
    }

    /// A buffer arriving before `start()` returns is the ordinary case, not an
    /// out-of-order one.
    func testInputBeforeSessionStartClosesTheDetector() {
        var monitor = CaptureWatchdogMonitor(budget)
        monitor.note(.engineStarted, atSeconds: 0.3)
        monitor.noteInputObserved()
        XCTAssertNil(monitor.evaluate(atSeconds: 20))
    }

    // MARK: - Maximum duration

    func testMaximumDurationWarnsOnceThenStops() {
        var monitor = CaptureWatchdogMonitor(budget)
        monitor.note(.engineStarted, atSeconds: 0.3)
        monitor.noteInputObserved()
        monitor.note(.sessionStarted, atSeconds: 0.5)
        XCTAssertNil(monitor.evaluate(atSeconds: 3299))
        XCTAssertEqual(monitor.evaluate(atSeconds: 3300), .maximumDurationWarning)
        XCTAssertNil(monitor.evaluate(atSeconds: 3400), "the warning must be raised once")
        XCTAssertEqual(monitor.evaluate(atSeconds: 3600), .maximumDuration)
    }

    func testMaximumDurationIsTerminal() {
        var monitor = CaptureWatchdogMonitor(budget)
        monitor.note(.sessionStarted, atSeconds: 0.5)
        monitor.note(.engineStarted, atSeconds: 0.3)
        monitor.noteInputObserved()
        XCTAssertEqual(monitor.evaluate(atSeconds: 3600), .maximumDuration)
        XCTAssertNil(monitor.evaluate(atSeconds: 3700))
    }

    // MARK: - Retirement

    func testRetiredMonitorNeverTrips() {
        var monitor = CaptureWatchdogMonitor(budget)
        monitor.retire()
        XCTAssertTrue(monitor.isRetired)
        XCTAssertNil(monitor.evaluate(atSeconds: 10_000))
    }

    func testOneTerminalTripOnly() {
        var monitor = CaptureWatchdogMonitor(budget)
        XCTAssertEqual(monitor.evaluate(atSeconds: 60), .startStalled(after: nil))
        XCTAssertNil(monitor.evaluate(atSeconds: 120))
        XCTAssertNil(monitor.evaluate(atSeconds: 4000))
    }

    // MARK: - Policy

    func testBatchFinalisationGetsTheLongerBudget() {
        XCTAssertGreaterThan(
            CaptureWatchdogPolicy.finalisationDeadlineSeconds(isBatch: true),
            CaptureWatchdogPolicy.finalisationDeadlineSeconds(isBatch: false)
        )
    }

    func testDefaultBudgetMatchesPolicy() {
        let defaults = CaptureWatchdogBudget()
        XCTAssertEqual(defaults.startDeadline, CaptureWatchdogPolicy.startDeadlineSeconds)
        XCTAssertEqual(defaults.firstInputDeadline, CaptureWatchdogPolicy.firstInputDeadlineSeconds)
        XCTAssertEqual(defaults.maximumDuration, CaptureWatchdogPolicy.maximumCaptureSeconds)
        XCTAssertEqual(
            defaults.maximumDurationWarningLead,
            CaptureWatchdogPolicy.maximumCaptureWarningLeadSeconds
        )
    }
}

/// The finalisation bound. Its sleep is injected, so both branches are proved
/// without waiting for either.
@MainActor
final class CaptureDeadlineTests: XCTestCase {
    func testValueArrivesBeforeTheDeadline() async throws {
        let value = try await CaptureDeadline.result(
            of: { 42 },
            orNilAfter: 30,
            sleep: { _ in await Task.yield() }
        )
        XCTAssertEqual(value, 42)
    }

    func testDeadlineWinsWhenTheWorkNeverReturns() async throws {
        let value: Int? = try await CaptureDeadline.result(
            of: {
                // Cancellation-aware only so the test's own task does not leak;
                // the point of the bound is that the caller stops waiting
                // whether or not the work ever notices.
                while !Task.isCancelled { await Task.yield() }
                return 1
            },
            orNilAfter: 0,
            sleep: { _ in await Task.yield() }
        )
        XCTAssertNil(value)
    }

    func testOperationErrorIsRethrownUnchanged() async {
        struct Boom: Error {}
        do {
            _ = try await CaptureDeadline.result(
                of: { () throws -> Int in throw Boom() },
                orNilAfter: 30,
                sleep: { _ in await Task.yield() }
            )
            XCTFail("expected the operation's error")
        } catch {
            XCTAssertTrue(error is Boom)
        }
    }
}
