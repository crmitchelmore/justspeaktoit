import SpeakCore
import XCTest

@testable import SpeakApp

/// Regression coverage for issue #668 — `NativeOSXLiveTranscriber` repainting
/// the live view with text from the previous recording.
///
/// `LiveTranscriptSessionIsolationTests` covers the socket-shaped controllers.
/// The local Apple recogniser differs in two ways that need their own coverage:
/// it is the default fallback controller, so back-to-back local recordings
/// really do share one cached instance, and `SFSpeechRecognitionTask.cancel()`
/// is not a hard stop — the recogniser can still deliver a queued result
/// afterwards. `LiveTranscriptDisplayScope` keys on the controller, which both
/// runs share, so only the per-run guard can tell them apart.
@MainActor
final class NativeOSXLiveTranscriptIsolationTests: XCTestCase {

  // MARK: - Doubles

  /// Mirrors `NativeOSXLiveTranscriber`'s run bookkeeping. The run identity is
  /// the per-run recognition request rather than the task, because
  /// `SFSpeechRecognizer` only hands the task back once its result handler has
  /// already been installed — too late for the handler to capture it. And
  /// `stop()` retires that identity *before* synthesising the result from the
  /// text the handler accumulated, so the guard must not swallow the final
  /// result.
  private final class RecognitionStubController: LiveTranscriptionController {
    weak var delegate: LiveTranscriptionSessionDelegate?
    var isRunning: Bool = false
    private(set) var request: RecognitionRequestStub?
    private var latestText: String = ""

    func configure(language: String?, model: String) {}

    @discardableResult
    func startRecognition() -> RecognitionRequestStub {
      let request = RecognitionRequestStub()
      self.request = request
      latestText = ""
      isRunning = true
      return request
    }

    func start() async throws {
      startRecognition()
    }

    func stop() async {
      finishRecognition()
    }

    /// Delivers a result as if the task installed on `request` produced it.
    /// A cancelled task can still call this long after its run has ended.
    func deliverResult(_ text: String, from request: RecognitionRequestStub) {
      guard LiveTranscriptionRun.isCurrent(request, activeStream: self.request) else { return }
      latestText = text
      delegate?.liveTranscriber(self, didUpdatePartial: text)
    }

    /// Production teardown order: retire the run identity, then finalise from
    /// the text the handler accumulated.
    func finishRecognition() {
      request = nil
      isRunning = false
      delegate?.liveTranscriber(
        self,
        didFinishWith: TranscriptionResult(
          text: latestText,
          segments: [],
          confidence: nil,
          duration: 1,
          modelIdentifier: AppleLocalModels.legacySpeechModelID,
          cost: nil,
          rawPayload: nil,
          debugInfo: nil
        )
      )
    }
  }

  /// Stands in for `SFSpeechAudioBufferRecognitionRequest`, the object minted
  /// fresh for every recognition run.
  private final class RecognitionRequestStub {}

  /// Records what a controller published, for the assertions about the delegate
  /// contract rather than the on-screen transcript.
  private final class RecordingDelegate: LiveTranscriptionSessionDelegate {
    private(set) var partials: [String] = []
    private(set) var finalText: String?

    func liveTranscriber(_ session: any LiveTranscriptionController, didUpdatePartial text: String) {
      partials.append(text)
    }

    func liveTranscriber(
      _ session: any LiveTranscriptionController,
      didUpdateWith update: LiveTranscriptionUpdate
    ) {}

    func liveTranscriber(
      _ session: any LiveTranscriptionController,
      didFinishWith result: TranscriptionResult
    ) {
      finalText = result.text
    }

    func liveTranscriber(_ session: any LiveTranscriptionController, didFail error: Error) {}

    func liveTranscriber(
      _ session: any LiveTranscriptionController,
      didDetectUtteranceBoundary utterance: String
    ) {}
  }

  private func makeManager() -> TranscriptionManager {
    let settings = AppSettings()
    let permissions = PermissionsManager()
    let audioDevices = AudioInputDeviceManager(appSettings: settings)
    let secureStorage = SecureAppStorage(
      permissionsManager: permissions,
      appSettings: settings,
      keychainService: "com.justspeaktoit.tests.native-osx-run.\(UUID().uuidString)"
    )
    let openRouter = OpenRouterAPIClient(secureStorage: secureStorage)
    return TranscriptionManager(
      appSettings: settings,
      permissionsManager: permissions,
      audioDeviceManager: audioDevices,
      batchClient: RemoteAudioTranscriber(client: openRouter),
      openRouter: openRouter,
      secureStorage: secureStorage
    )
  }

  // MARK: - Tests

  func testStaleRecognitionResultOnReusedController_isDroppedDuringTheNextSession() {
    let manager = self.makeManager()
    let controller = RecognitionStubController()
    controller.delegate = manager

    let firstRequest = controller.startRecognition()
    manager.beginLiveTranscriptDisplaySession(source: controller)
    controller.deliverResult("first recording", from: firstRequest)
    XCTAssertEqual(manager.livePartialText, "first recording")
    controller.finishRecognition()
    manager.endLiveTranscriptDisplaySession()

    // Next recording: same cached controller, a brand new recognition request.
    let secondRequest = controller.startRecognition()
    manager.beginLiveTranscriptDisplaySession(source: controller)
    controller.deliverResult("second recording", from: secondRequest)
    XCTAssertEqual(manager.livePartialText, "second recording")

    XCTAssertTrue(
      manager.displayScope.accepts(controller),
      "The session guard cannot catch this — the stale result shares the controller"
    )
    controller.deliverResult("first recording", from: firstRequest)

    XCTAssertEqual(
      manager.livePartialText,
      "second recording",
      "A result from the previous recognition request must not repaint the live view"
    )
  }

  /// The recogniser's own final result is dropped by the guard, because `stop()`
  /// retires the run identity before tearing the task down. That is only safe
  /// because the finished result is synthesised from state the handler already
  /// accumulated — this pins that ordering.
  func testRetiringTheRecognitionRun_stillPublishesTheAccumulatedFinalResult() {
    let recorder = RecordingDelegate()
    let controller = RecognitionStubController()
    controller.delegate = recorder

    let request = controller.startRecognition()
    controller.deliverResult("hello world", from: request)
    controller.finishRecognition()

    XCTAssertEqual(
      recorder.finalText,
      "hello world",
      "Retiring the run identity must not swallow the recording's final text"
    )

    controller.deliverResult("late result", from: request)
    XCTAssertEqual(
      recorder.partials,
      ["hello world"],
      "A result delivered after the run is retired must not reach the delegate"
    )
  }

  /// A mid-session restart (Apple's recogniser emits `isFinal` on a pause)
  /// mints a replacement request, which retires the previous one.
  func testMidSessionRestart_dropsResultsFromTheSupersededRequest() {
    let manager = self.makeManager()
    let controller = RecognitionStubController()
    controller.delegate = manager

    let firstRequest = controller.startRecognition()
    manager.beginLiveTranscriptDisplaySession(source: controller)
    controller.deliverResult("before the pause", from: firstRequest)

    let restartedRequest = controller.startRecognition()
    controller.deliverResult("after the pause", from: restartedRequest)
    controller.deliverResult("before the pause", from: firstRequest)

    XCTAssertEqual(
      manager.livePartialText,
      "after the pause",
      "The cancelled task's queued results must not survive the restart"
    )
  }
}
