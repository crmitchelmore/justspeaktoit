import XCTest

@testable import SpeakApp

@MainActor
final class VoiceEditOrchestratorTests: XCTestCase {
    private typealias Harness = VoiceEditOrchestratorHarness

    // MARK: - Happy path

    func testFullFlow_replacesSelectionAndReturnsToIdle() async {
        let harness = Harness()
        await harness.orchestrator.toggle()

        XCTAssertEqual(harness.orchestrator.phase, .listening)
        XCTAssertEqual(harness.events, [.listeningStarted(.accessibility)])
        XCTAssertEqual(harness.startCount, 1)

        await harness.orchestrator.toggle()

        XCTAssertEqual(harness.orchestrator.phase, .idle)
        XCTAssertEqual(
            harness.events,
            [
                .listeningStarted(.accessibility),
                .transcribingInstruction,
                .rewriting,
                .applying,
                .finished(.replaced)
            ]
        )
        XCTAssertEqual(harness.finishCount, 1)
        XCTAssertEqual(harness.rewriteRequests.count, 1)
        XCTAssertEqual(
            harness.rewriteRequests.first?.selection,
            "The quick brown fox jumps over the lazy dog"
        )
        XCTAssertEqual(harness.rewriteRequests.first?.instruction, "make this shorter")
        XCTAssertEqual(harness.appliedRewrites, ["Quick fox, lazy dog."])
    }

    func testSpokenInstruction_isTrimmedBeforeRewrite() async {
        let harness = Harness()
        harness.instructionResult = .success("  turn this into bullets \n")

        await harness.orchestrator.toggle()
        await harness.orchestrator.toggle()

        XCTAssertEqual(harness.rewriteRequests.first?.instruction, "turn this into bullets")
    }

    func testLastInsertionFallbackSource_isReportedInListeningEvent() async {
        let harness = Harness()
        harness.selection = .init(text: "previous dictation", source: .lastInsertion)

        await harness.orchestrator.toggle()

        XCTAssertEqual(harness.events, [.listeningStarted(.lastInsertion)])
    }

    func testClipboardReplacementOutcome_isPropagated() async {
        let harness = Harness()
        harness.replacementOutcome = .leftOnClipboard(.selectionChanged)

        await harness.orchestrator.toggle()
        await harness.orchestrator.toggle()

        XCTAssertEqual(harness.events.last, .finished(.leftOnClipboard(.selectionChanged)))
        XCTAssertEqual(harness.orchestrator.phase, .idle)
    }

    // MARK: - Guard rails

    func testDictationBusy_failsWithoutCapturingOrRecording() async {
        let harness = Harness()
        harness.busy = true

        await harness.orchestrator.toggle()

        XCTAssertEqual(harness.events, [.failed(.dictationBusy)])
        XCTAssertEqual(harness.captureCount, 0)
        XCTAssertEqual(harness.startCount, 0)
        XCTAssertEqual(harness.orchestrator.phase, .idle)
    }

    func testMissingLLM_failsBeforeTouchingTheSelection() async {
        let harness = Harness()
        harness.llmConfigured = false

        await harness.orchestrator.toggle()

        XCTAssertEqual(harness.events, [.failed(.noConfiguredLLM)])
        XCTAssertEqual(harness.captureCount, 0)
    }

    func testNoSelection_failsWithoutStartingRecording() async {
        let harness = Harness()
        harness.selection = nil

        await harness.orchestrator.toggle()

        XCTAssertEqual(harness.events, [.failed(.noSelection)])
        XCTAssertEqual(harness.startCount, 0)
        XCTAssertEqual(harness.orchestrator.phase, .idle)
    }

    func testEmptySelectionText_isTreatedAsNoSelection() async {
        let harness = Harness()
        harness.selection = .init(text: "", source: .accessibility)

        await harness.orchestrator.toggle()

        XCTAssertEqual(harness.events, [.failed(.noSelection)])
    }

    func testRecordingStartFailure_reportsAndStaysIdle() async {
        let harness = Harness()
        harness.startError = VoiceEditStubError(message: "mic unavailable")

        await harness.orchestrator.toggle()

        XCTAssertEqual(harness.events, [.failed(.recordingFailed("mic unavailable"))])
        XCTAssertEqual(harness.orchestrator.phase, .idle)
    }

    // MARK: - Finish-stage failures

    func testEmptyInstruction_failsWithoutCallingTheModel() async {
        let harness = Harness()
        harness.instructionResult = .success("   \n ")

        await harness.orchestrator.toggle()
        await harness.orchestrator.toggle()

        XCTAssertEqual(harness.events.last, .failed(.emptyInstruction))
        XCTAssertTrue(harness.rewriteRequests.isEmpty)
        XCTAssertTrue(harness.appliedRewrites.isEmpty)
        XCTAssertEqual(harness.orchestrator.phase, .idle)
    }

    func testTranscriptionFailure_isReported() async {
        let harness = Harness()
        harness.instructionResult = .failure(VoiceEditStubError(message: "provider offline"))

        await harness.orchestrator.toggle()
        await harness.orchestrator.toggle()

        XCTAssertEqual(harness.events.last, .failed(.transcriptionFailed("provider offline")))
        XCTAssertTrue(harness.rewriteRequests.isEmpty)
    }

    func testRewriteFailure_isReportedWithoutApplying() async {
        let harness = Harness()
        harness.rewriteResult = .failure(VoiceEditStubError(message: "429 rate limited"))

        await harness.orchestrator.toggle()
        await harness.orchestrator.toggle()

        XCTAssertEqual(harness.events.last, .failed(.rewriteFailed("429 rate limited")))
        XCTAssertTrue(harness.appliedRewrites.isEmpty)
        XCTAssertEqual(harness.orchestrator.phase, .idle)
    }

    func testEmptyRewrite_isTreatedAsFailure() async {
        let harness = Harness()
        harness.rewriteResult = .success("")

        await harness.orchestrator.toggle()
        await harness.orchestrator.toggle()

        XCTAssertEqual(
            harness.events.last,
            .failed(.rewriteFailed("The model returned an empty rewrite."))
        )
        XCTAssertTrue(harness.appliedRewrites.isEmpty)
    }

    func testSessionAfterFailure_startsCleanly() async {
        let harness = Harness()
        harness.selection = nil
        await harness.orchestrator.toggle()
        XCTAssertEqual(harness.events, [.failed(.noSelection)])

        harness.selection = .init(text: "second try", source: .clipboard)
        await harness.orchestrator.toggle()

        XCTAssertEqual(harness.events.last, .listeningStarted(.clipboard))
        XCTAssertEqual(harness.orchestrator.phase, .listening)
    }

    func testSecondPressDuringStartup_doesNotStartAParallelSession() async {
        let harness = Harness()
        let captureEntered = expectation(description: "selection capture entered")
        let gate = VoiceEditTestGate()
        harness.captureGate = {
            captureEntered.fulfill()
            await gate.wait()
        }

        let firstPress = Task { await harness.orchestrator.toggle() }
        await fulfillment(of: [captureEntered], timeout: 2)

        await harness.orchestrator.toggle()
        XCTAssertEqual(harness.captureCount, 1)
        XCTAssertEqual(harness.startCount, 0)

        gate.open()
        await firstPress.value

        XCTAssertEqual(harness.captureCount, 1)
        XCTAssertEqual(harness.startCount, 1)
        XCTAssertEqual(harness.events, [.listeningStarted(.accessibility)])
        XCTAssertEqual(harness.orchestrator.phase, .listening)
    }
}
