#if os(iOS)
import Foundation
import SpeakCore
import XCTest
@testable import SpeakiOSLib

@MainActor
final class CaptureHealthReporterTests: XCTestCase {
    func testEveryPublicationGetsAFreshTokenAndNilClearsIt() {
        var reporter = CaptureHealthReporter(journalDefaults: { nil })
        let error = iOSTranscriptionError.finalisationTimedOut
        let first = reporter.publishSessionError(error)
        let second = reporter.publishSessionError(error)
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertNotEqual(first, second, "An identical failure is still a new event (#1084)")
        XCTAssertNil(reporter.publishSessionError(nil))
    }

    func testStagedFailureIsPublishedOnceUnderItsToken() throws {
        var reporter = CaptureHealthReporter(journalDefaults: { nil })
        let run = UUID()
        reporter.requests.begin(run)
        reporter.requests.admit(.init(model: .project("gladia/solaria-1-streaming")), run: run)
        reporter.stageFailure(iOSTranscriptionError.finalisationTimedOut, failure: .init(stage: .request), run: run)
        let token = try XCTUnwrap(reporter.publishSessionError(iOSTranscriptionError.finalisationTimedOut))
        XCTAssertTrue(reporter.snapshot(for: token).full.jsonString.contains("gladia/solaria-1-streaming"))

        // The staged snapshot is consumed: the next publication gets the generic report.
        let next = try XCTUnwrap(reporter.publishSessionError(iOSTranscriptionError.finalisationTimedOut))
        XCTAssertFalse(reporter.snapshot(for: next).full.jsonString.contains("gladia/solaria-1-streaming"))
    }

    func testCancellationStagesNoSnapshot() throws {
        var reporter = CaptureHealthReporter(journalDefaults: { nil })
        let run = UUID()
        reporter.requests.begin(run)
        reporter.requests.admit(.init(model: .project("gladia/solaria-1-streaming")), run: run)
        reporter.stageFailure(CancellationError(), failure: .init(stage: .request), run: run)
        let token = try XCTUnwrap(reporter.publishSessionError(CancellationError()))
        XCTAssertFalse(reporter.snapshot(for: token).full.jsonString.contains("gladia/solaria-1-streaming"))
    }

    func testJournalWritesThroughTheInjectedDefaults() throws {
        let suite = "CaptureHealthReporterTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let reporter = CaptureHealthReporter(journalDefaults: { defaults })

        reporter.journal(failure: iOSTranscriptionError.finalisationTimedOut)
        XCTAssertEqual(CaptureOutcomeJournal.lastFailureCode(defaults: defaults), "start_finalisation_timeout")
        reporter.journal(.delivered, failure: nil)
        XCTAssertNil(CaptureOutcomeJournal.lastFailureCode(defaults: defaults))
    }
}
#endif
