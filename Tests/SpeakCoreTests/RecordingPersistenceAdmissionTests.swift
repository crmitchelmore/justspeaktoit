import XCTest

@testable import SpeakCore

/// Bounded persistence admission (issue #705): short stalls are absorbed via
/// fallback allocations, sustained overflow drops frames with exact gap
/// accounting, write failures are counted, and a recording with any drop or
/// failure can never report itself complete.
final class RecordingPersistenceAdmissionTests: XCTestCase {
    /// 100 ms frames, the app's live-capture cadence.
    private let frame = 0.1

    func testSteadyState_poolBackedFramesAreAcceptedAndComplete() {
        let controller = RecordingPersistenceAdmissionController(overflowBudgetSeconds: 2)
        for _ in 0..<50 {
            XCTAssertEqual(controller.admit(frameSeconds: frame, poolHasCapacity: true), .accepted)
            controller.completeWrite(frameSeconds: frame, failed: false)
        }
        let diagnostics = controller.diagnostics
        XCTAssertEqual(diagnostics.admittedFrames, 50)
        XCTAssertEqual(diagnostics.droppedFrames, 0)
        XCTAssertEqual(diagnostics.overflowAllocations, 0)
        XCTAssertTrue(diagnostics.isComplete)
    }

    func testTemporaryStall_isAbsorbedByOverflowAndRecovers() {
        let controller = RecordingPersistenceAdmissionController(overflowBudgetSeconds: 2)

        // The writer stalls: the pool is exhausted, but the duration budget
        // absorbs one second of audio via fallback allocations.
        for _ in 0..<10 {
            XCTAssertEqual(
                controller.admit(frameSeconds: frame, poolHasCapacity: false),
                .acceptedViaOverflow
            )
        }
        // The writer catches up; everything admitted lands.
        for _ in 0..<10 {
            controller.completeWrite(frameSeconds: frame, failed: false)
        }
        XCTAssertEqual(controller.admit(frameSeconds: frame, poolHasCapacity: true), .accepted)

        let diagnostics = controller.diagnostics
        XCTAssertEqual(diagnostics.overflowAllocations, 10)
        XCTAssertEqual(diagnostics.droppedFrames, 0)
        XCTAssertTrue(diagnostics.isComplete, "a fully absorbed stall is still a complete recording")
        XCTAssertEqual(diagnostics.inFlightHighWaterSeconds, 1.0, accuracy: 0.0001)
    }

    func testSustainedOverflow_dropsFramesWithExactGapAccounting() {
        let controller = RecordingPersistenceAdmissionController(overflowBudgetSeconds: 1)

        // Nothing ever completes: the budget admits ten frames, then drops.
        var admitted = 0
        var dropped = 0
        for _ in 0..<25 {
            switch controller.admit(frameSeconds: frame, poolHasCapacity: false) {
            case .accepted, .acceptedViaOverflow: admitted += 1
            case .backpressured: dropped += 1
            }
        }
        XCTAssertEqual(admitted, 10)
        XCTAssertEqual(dropped, 15)

        let diagnostics = controller.diagnostics
        XCTAssertEqual(diagnostics.droppedFrames, 15)
        XCTAssertEqual(diagnostics.droppedSeconds, 1.5, accuracy: 0.0001)
        XCTAssertFalse(
            diagnostics.isComplete,
            "sustained overflow must never present a complete recording"
        )
    }

    func testWriteFailure_marksTheRecordingIncomplete() {
        let controller = RecordingPersistenceAdmissionController(overflowBudgetSeconds: 2)
        XCTAssertEqual(controller.admit(frameSeconds: frame, poolHasCapacity: true), .accepted)
        controller.completeWrite(frameSeconds: frame, failed: true)

        let diagnostics = controller.diagnostics
        XCTAssertEqual(diagnostics.writeFailures, 1)
        XCTAssertFalse(diagnostics.isComplete)
    }

    func testStopWhileBackpressured_reportsTheGapInFinalDiagnostics() {
        let controller = RecordingPersistenceAdmissionController(overflowBudgetSeconds: 0.5)
        for _ in 0..<5 {
            _ = controller.admit(frameSeconds: frame, poolHasCapacity: false)
        }
        // Budget full; these frames are the user's audio that never made it.
        for _ in 0..<3 {
            XCTAssertEqual(
                controller.admit(frameSeconds: frame, poolHasCapacity: false),
                .backpressured
            )
        }
        // Stop drains the queue: the admitted frames land, the dropped ones
        // stay recorded as the gap they are.
        for _ in 0..<5 {
            controller.completeWrite(frameSeconds: frame, failed: false)
        }

        let diagnostics = controller.diagnostics
        XCTAssertEqual(diagnostics.admittedFrames, 5)
        XCTAssertEqual(diagnostics.droppedFrames, 3)
        XCTAssertEqual(diagnostics.droppedSeconds, 0.3, accuracy: 0.0001)
        XCTAssertFalse(diagnostics.isComplete)
    }

    func testFailedFallbackAllocation_isAccountedAsDroppedAudio() {
        let controller = RecordingPersistenceAdmissionController(overflowBudgetSeconds: 2)
        XCTAssertEqual(controller.admit(frameSeconds: frame, poolHasCapacity: true), .accepted)
        controller.completeWrite(frameSeconds: frame, failed: false)

        // Admission granted via overflow, but the allocation itself fails: the
        // frame is gone, so it is a gap — not a write that failed.
        XCTAssertEqual(
            controller.admit(frameSeconds: frame, poolHasCapacity: false),
            .acceptedViaOverflow
        )
        controller.abandonAdmittedFrame(frameSeconds: frame)

        let diagnostics = controller.diagnostics
        XCTAssertEqual(diagnostics.admittedFrames, 1, "the abandoned admission is reversed")
        XCTAssertEqual(diagnostics.admittedSeconds, frame, accuracy: 0.0001)
        XCTAssertEqual(diagnostics.overflowAllocations, 0, "no fallback allocation was actually used")
        XCTAssertEqual(diagnostics.droppedFrames, 1)
        XCTAssertEqual(diagnostics.droppedSeconds, frame, accuracy: 0.0001)
        XCTAssertEqual(diagnostics.writeFailures, 0)
        XCTAssertFalse(diagnostics.isComplete)

        // The budget was released: the next overflow frame is admitted again.
        XCTAssertEqual(controller.inFlightSecondsForTesting, 0, accuracy: 0.0001)
    }

    func testPoolCapacity_neverConsultsTheOverflowBudget() {
        // A zero-budget controller still admits every pool-backed frame: the
        // budget only governs fallback allocations.
        let controller = RecordingPersistenceAdmissionController(overflowBudgetSeconds: 0)
        XCTAssertEqual(controller.admit(frameSeconds: frame, poolHasCapacity: true), .accepted)
        XCTAssertEqual(
            controller.admit(frameSeconds: frame, poolHasCapacity: false),
            .backpressured
        )
    }

    func testHighWaterMark_recordsThePeakNotTheCurrent() {
        let controller = RecordingPersistenceAdmissionController(overflowBudgetSeconds: 2)
        for _ in 0..<8 {
            _ = controller.admit(frameSeconds: frame, poolHasCapacity: true)
        }
        for _ in 0..<8 {
            controller.completeWrite(frameSeconds: frame, failed: false)
        }
        _ = controller.admit(frameSeconds: frame, poolHasCapacity: true)

        XCTAssertEqual(controller.diagnostics.inFlightHighWaterSeconds, 0.8, accuracy: 0.0001)
    }
}
