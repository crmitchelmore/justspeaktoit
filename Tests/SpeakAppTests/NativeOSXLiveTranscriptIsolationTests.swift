import XCTest

@testable import SpeakApp

private final class RecognitionTaskDouble: NativeSpeechRecognitionTask {
  private(set) var isCancelled = false

  func cancel() {
    isCancelled = true
  }
}

@MainActor
private final class RecognitionTaskFactoryDouble {
  private(set) var callbacks: [NativeSpeechRecognitionTaskLifecycle.Callback] = []
  private(set) var tasks: [RecognitionTaskDouble] = []

  func makeTask(callback: @escaping NativeSpeechRecognitionTaskLifecycle.Callback) -> any NativeSpeechRecognitionTask {
    let task = RecognitionTaskDouble()
    callbacks.append(callback)
    tasks.append(task)
    return task
  }

  func sendResult(_ text: String, isFinal: Bool = false, task index: Int) {
    callbacks[index](NativeSpeechRecognitionResult(text: text, isFinal: isFinal), nil)
  }

  func sendError(task index: Int) {
    callbacks[index](nil, TestError.recognitionFailed)
  }
}

private enum TestError: Error {
  case recognitionFailed
}

/// Drives the callback seam used by `NativeOSXLiveTranscriber` in production.
/// No test-side copy of the identity guard exists here: delayed callbacks are
/// admitted or rejected only by `NativeSpeechRecognitionTaskLifecycle`.
@MainActor
final class NativeOSXLiveTranscriptIsolationTests: XCTestCase {
  func testCallbacksAfterStop_areDroppedForResultsAndErrors() async {
    let (lifecycle, factory, events) = makeLifecycle()
    start(lifecycle, factory: factory, events: events)
    factory.sendResult("current", task: 0)
    factory.sendError(task: 0)
    await drainCallbacks()

    lifecycle.retire()
    factory.sendResult("stale after stop", task: 0)
    factory.sendError(task: 0)
    await drainCallbacks()

    XCTAssertTrue(factory.tasks[0].isCancelled)
    XCTAssertEqual(events.results, ["current"])
    XCTAssertEqual(events.errorCount, 1)
  }

  func testReusedLifecycle_acceptsCurrentCallbacksAndDropsPreviousRun() async {
    let (lifecycle, factory, events) = makeLifecycle()
    start(lifecycle, factory: factory, events: events)
    lifecycle.retire()
    start(lifecycle, factory: factory, events: events)

    factory.sendResult("stale result", task: 0)
    factory.sendError(task: 0)
    factory.sendResult("current result", task: 1)
    factory.sendError(task: 1)
    await drainCallbacks()

    XCTAssertEqual(events.results, ["current result"])
    XCTAssertEqual(events.errorCount, 1)
  }

  func testMidSessionRestart_retiresBothResultAndErrorCallbacksFromCancelledTask() async {
    let (lifecycle, factory, events) = makeLifecycle()
    start(lifecycle, factory: factory, events: events)

    // `NativeOSXLiveTranscriber.restartRecognitionTask()` starts a replacement
    // lifecycle task after Apple's mid-session final result.
    start(lifecycle, factory: factory, events: events)
    factory.sendResult("before restart", isFinal: true, task: 0)
    factory.sendError(task: 0)
    factory.sendResult("after restart", task: 1)
    factory.sendError(task: 1)
    await drainCallbacks()

    XCTAssertTrue(factory.tasks[0].isCancelled)
    XCTAssertEqual(events.results, ["after restart"])
    XCTAssertEqual(events.errorCount, 1)
  }

  private func makeLifecycle() -> (
    NativeSpeechRecognitionTaskLifecycle,
    RecognitionTaskFactoryDouble,
    RecognitionEvents
  ) {
    (NativeSpeechRecognitionTaskLifecycle(), RecognitionTaskFactoryDouble(), RecognitionEvents())
  }

  private func start(
    _ lifecycle: NativeSpeechRecognitionTaskLifecycle,
    factory: RecognitionTaskFactoryDouble,
    events: RecognitionEvents
  ) {
    lifecycle.start(
      factory: { factory.makeTask(callback: $0) },
      onEvent: { result, error in
        if let result { events.results.append(result.text) }
        if error != nil { events.errorCount += 1 }
      }
    )
  }

  private func drainCallbacks() async {
    for _ in 0..<3 { await Task.yield() }
  }
}

@MainActor
private final class RecognitionEvents {
  var results: [String] = []
  var errorCount = 0
}
