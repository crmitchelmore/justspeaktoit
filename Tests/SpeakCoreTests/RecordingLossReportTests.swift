import XCTest
@testable import SpeakCore

final class RecordingLossReportTests: XCTestCase {
    func testVariablePCMFormats_countBuffersAndActualDuration() {
        let report = RecordingLossReport()
        report.rejectCapture(frameLength: 4_800, sampleRate: 48_000)
        report.rejectCapture(frameLength: 2_205, sampleRate: 44_100)
        let snapshot = report.finish(persistence: nil)
        XCTAssertEqual(snapshot.rejectedBuffers, 2)
        XCTAssertEqual(snapshot.captureSeconds, 0.15, accuracy: 0.000001)
        XCTAssertEqual(snapshot.persistence.droppedFrames, 0)
        XCTAssertEqual(snapshot.summary, "Some microphone audio was missed: 2 buffers (0.150 s).")
    }

    func testAcceptedOverflow_doesNotWarn() {
        let writer = RecordingPersistenceAdmissionController()
        XCTAssertEqual(writer.admit(frameSeconds: 0.1, poolHasCapacity: false), .acceptedViaOverflow)
        writer.completeWrite(frameSeconds: 0.1, failed: false)
        let report = RecordingLossReport()
        report.recordPersistence(writer.diagnostics)
        XCTAssertNil(report.finish(persistence: writer.diagnostics).summary)
    }

    func testDrainedTotals_overrideDelayedFirstNotificationAndRemainSeparate() {
        let report = RecordingLossReport()
        report.rejectCapture(frameLength: 480, sampleRate: 48_000)
        var initial = RecordingPersistenceDiagnostics()
        initial.writeFailures = 1
        report.recordPersistence(initial)
        var final = initial
        final.writeFailures = 3
        final.droppedFrames = 2
        final.droppedSeconds = 0.2
        let snapshot = report.finish(persistence: final)
        report.recordPersistence(initial)
        report.rejectCapture(frameLength: 480, sampleRate: 48_000)
        XCTAssertEqual(report.snapshot, snapshot)
        XCTAssertEqual(snapshot.rejectedBuffers, 1)
        XCTAssertEqual(snapshot.persistence.writeFailures, 3)
        XCTAssertTrue(snapshot.summary?.contains("2 writer drops (0.200 s), 3 write failures") == true)
        XCTAssertNil(RecordingLossReport().snapshot.summary)
    }

    func testConcurrentCaptureRejections_areCountedExactly() {
        let report = RecordingLossReport()
        DispatchQueue.concurrentPerform(iterations: 1_000) { _ in
            report.rejectCapture(frameLength: 480, sampleRate: 48_000)
        }
        XCTAssertEqual(report.snapshot.rejectedBuffers, 1_000)
        XCTAssertEqual(report.snapshot.captureSeconds, 10, accuracy: 0.000001)
    }
}
