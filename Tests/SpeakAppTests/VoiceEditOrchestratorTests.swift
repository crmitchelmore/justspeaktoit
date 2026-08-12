import XCTest

@testable import SpeakApp

@MainActor
final class VoiceEditOrchestratorTests: XCTestCase {
  private struct StubError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
  }

  /// Test double owning every orchestrator seam, so each test tweaks only what it needs.
  @MainActor
  private final class Harness {
    var busy = false
    var llmConfigured = true
    var selection: VoiceEditOrchestrator.Selection? = .init(
      text: "The quick brown fox jumps over the lazy dog",
      source: .accessibility
    )
    var startError: Error?
    var instructionResult: Result<String, Error> = .success("make this shorter")
    var rewriteResult: Result<String, Error> = .success("Quick fox, lazy dog.")
    var replacementOutcome: VoiceEditOrchestrator.ReplacementOutcome = .replaced
    /// Suspends selection capture so tests can press the hotkey again mid-startup.
    var captureGate: (() async -> Void)?

    private(set) var events: [VoiceEditOrchestrator.Event] = []
    private(set) var captureCount = 0
    private(set) var startCount = 0
    private(set) var finishCount = 0
    private(set) var cancelCount = 0
    private(set) var rewriteRequests: [(selection: String, instruction: String)] = []
    private(set) var appliedRewrites: [String] = []

    lazy var orchestrator = VoiceEditOrchestrator(
      dependencies: .init(
        isDictationBusy: { self.busy },
        hasConfiguredLLM: { self.llmConfigured },
        captureSelection: {
          self.captureCount += 1
          await self.captureGate?()
          return self.selection
        },
        startListening: {
          self.startCount += 1
          if let error = self.startError { throw error }
        },
        finishListening: {
          self.finishCount += 1
          return try self.instructionResult.get()
        },
        cancelListening: { self.cancelCount += 1 },
        rewrite: { selection, instruction in
          self.rewriteRequests.append((selection.text, instruction))
          return try self.rewriteResult.get()
        },
        applyReplacement: { _, rewrite in
          self.appliedRewrites.append(rewrite)
          return self.replacementOutcome
        },
        onEvent: { self.events.append($0) }
      )
    )
  }

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
    harness.replacementOutcome = .leftOnClipboard

    await harness.orchestrator.toggle()
    await harness.orchestrator.toggle()

    XCTAssertEqual(harness.events.last, .finished(.leftOnClipboard))
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
    harness.startError = StubError(message: "mic unavailable")

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
    harness.instructionResult = .failure(StubError(message: "provider offline"))

    await harness.orchestrator.toggle()
    await harness.orchestrator.toggle()

    XCTAssertEqual(harness.events.last, .failed(.transcriptionFailed("provider offline")))
    XCTAssertTrue(harness.rewriteRequests.isEmpty)
  }

  func testRewriteFailure_isReportedWithoutApplying() async {
    let harness = Harness()
    harness.rewriteResult = .failure(StubError(message: "429 rate limited"))

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

  // MARK: - Cancellation

  func testCancelDuringListening_stopsRecordingAndEmitsCancelled() async {
    let harness = Harness()
    await harness.orchestrator.toggle()

    harness.orchestrator.cancel()

    XCTAssertEqual(harness.cancelCount, 1)
    XCTAssertEqual(harness.events.last, .cancelled)
    XCTAssertEqual(harness.orchestrator.phase, .idle)
    XCTAssertEqual(harness.finishCount, 0)
  }

  func testCancelWhenIdle_isANoOp() {
    let harness = Harness()

    harness.orchestrator.cancel()

    XCTAssertTrue(harness.events.isEmpty)
    XCTAssertEqual(harness.cancelCount, 0)
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
    let gate = Gate()
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

/// One-shot gate used to hold an orchestrator dependency at a suspension point.
@MainActor
private final class Gate {
  private var continuation: CheckedContinuation<Void, Never>?
  private var isOpen = false

  func wait() async {
    guard !self.isOpen else { return }
    await withCheckedContinuation { self.continuation = $0 }
  }

  func open() {
    self.isOpen = true
    self.continuation?.resume()
    self.continuation = nil
  }
}
