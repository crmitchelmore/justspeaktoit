import SpeakCore
import XCTest

@testable import SpeakApp

/// Regression coverage for issue #643 — the live transcript view flickering
/// with text left over from the previous recording.
///
/// These tests drive the real `TranscriptionManager` delegate entry points with
/// stub controllers, which is the boundary where a superseded recording's
/// WebSocket/recogniser callbacks arrive late, out of order, or interleaved
/// with the next recording.
@MainActor
final class LiveTranscriptSessionIsolationTests: XCTestCase {

  // MARK: - Doubles

  private final class StubLiveController: LiveTranscriptionController {
    weak var delegate: LiveTranscriptionSessionDelegate?
    var isRunning: Bool = false
    func configure(language: String?, model: String) {}
    func start() async throws {}
    func stop() async {}
  }

  /// Mirrors the production controller shape: one cached controller instance
  /// that mints a fresh stream object per recording and routes stream
  /// callbacks through `LiveTranscriptionRun`.
  private final class StreamingStubController: LiveTranscriptionController {
    final class Stream {}

    weak var delegate: LiveTranscriptionSessionDelegate?
    var isRunning: Bool = false
    private(set) var stream: Stream?

    func configure(language: String?, model: String) {}

    @discardableResult
    func startStream() -> Stream {
      let stream = Stream()
      self.stream = stream
      isRunning = true
      return stream
    }

    func start() async throws {
      startStream()
    }

    func stop() async {
      isRunning = false
    }

    /// Delivers a partial as if it arrived on `stream`'s socket.
    func deliverPartial(_ text: String, from stream: Stream) {
      guard LiveTranscriptionRun.isCurrent(stream, activeStream: self.stream) else { return }
      delegate?.liveTranscriber(self, didUpdatePartial: text)
    }
  }

  private func makeSwitchingTranscriber() -> SwitchingLiveTranscriber {
    let settings = AppSettings()
    let permissions = PermissionsManager()
    let audioDevices = AudioInputDeviceManager(appSettings: settings)
    let secureStorage = SecureAppStorage(
      permissionsManager: permissions,
      appSettings: settings,
      keychainService: "com.justspeaktoit.tests.live-session.\(UUID().uuidString)"
    )
    return SwitchingLiveTranscriber(
      appSettings: settings,
      permissionsManager: permissions,
      audioDeviceManager: audioDevices,
      secureStorage: secureStorage
    )
  }

  private func makeManager() -> TranscriptionManager {
    let settings = AppSettings()
    let permissions = PermissionsManager()
    let audioDevices = AudioInputDeviceManager(appSettings: settings)
    let secureStorage = SecureAppStorage(
      permissionsManager: permissions,
      appSettings: settings,
      keychainService: "com.justspeaktoit.tests.live-session.\(UUID().uuidString)"
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

  private func makeResult(_ text: String) -> TranscriptionResult {
    TranscriptionResult(
      text: text,
      segments: [],
      confidence: nil,
      duration: 1,
      modelIdentifier: "soniox/stt-rt-v5-streaming",
      cost: nil,
      rawPayload: nil,
      debugInfo: nil
    )
  }

  // MARK: - Sequential recordings

  func testLatePartialFromPreviousRecording_doesNotReplaceCurrentTranscript() {
    let manager = self.makeManager()
    let previous = StubLiveController()

    manager.beginLiveTranscriptDisplaySession(source: previous)
    manager.liveTranscriber(previous, didUpdatePartial: "previous recording text")
    XCTAssertEqual(manager.livePartialText, "previous recording text")
    manager.endLiveTranscriptDisplaySession()

    let current = StubLiveController()
    manager.beginLiveTranscriptDisplaySession(source: current)
    XCTAssertEqual(manager.livePartialText, "", "A new recording must start from a blank transcript")

    manager.liveTranscriber(current, didUpdatePartial: "current recording")
    manager.liveTranscriber(previous, didUpdatePartial: "previous recording text")

    XCTAssertEqual(
      manager.livePartialText,
      "current recording",
      "A late partial from the previous recording must not repaint the live view"
    )
  }

  func testRapidSequentialRecordings_reusingOneController_dropSupersededUpdates() {
    let manager = self.makeManager()
    // Cached controllers are reused between recordings, so the same instance
    // reports both sessions.
    let controller = StubLiveController()

    manager.beginLiveTranscriptDisplaySession(source: controller)
    manager.liveTranscriber(controller, didUpdatePartial: "first")
    manager.liveTranscriber(controller, didFinishWith: self.makeResult("first"))
    manager.endLiveTranscriptDisplaySession()

    manager.beginLiveTranscriptDisplaySession(source: controller)
    manager.liveTranscriber(controller, didUpdatePartial: "second")
    let secondSession = manager.liveTranscript.sessionID

    manager.endLiveTranscriptDisplaySession()
    manager.liveTranscriber(controller, didUpdatePartial: "first")

    XCTAssertEqual(manager.livePartialText, "second")
    XCTAssertEqual(
      manager.liveTranscript.sessionID,
      secondSession,
      "Updates arriving after a session ends must not be attributed to it"
    )
  }

  func testDelayedFinalFromPreviousRecording_doesNotOverwriteCurrentTranscript() {
    let manager = self.makeManager()
    let previous = StubLiveController()
    manager.beginLiveTranscriptDisplaySession(source: previous)
    manager.liveTranscriber(previous, didUpdatePartial: "previous")
    manager.endLiveTranscriptDisplaySession()

    let current = StubLiveController()
    manager.beginLiveTranscriptDisplaySession(source: current)
    manager.liveTranscriber(
      current,
      didUpdateWith: LiveTranscriptionUpdate(text: "current", isFinal: false, confidence: 0.9)
    )

    manager.liveTranscriber(previous, didFinishWith: self.makeResult("previous"))
    manager.liveTranscriber(
      previous,
      didUpdateWith: LiveTranscriptionUpdate(text: "previous", isFinal: true, confidence: 0.1)
    )

    XCTAssertEqual(manager.livePartialText, "current")
    XCTAssertEqual(manager.liveTranscript.confidence, 0.9)
    XCTAssertFalse(manager.liveTranscript.isFinal)
  }

  func testOutOfOrderUtteranceBoundary_fromPreviousRecording_isIgnored() {
    let manager = self.makeManager()
    let previous = StubLiveController()
    manager.beginLiveTranscriptDisplaySession(source: previous)
    manager.endLiveTranscriptDisplaySession()

    let current = StubLiveController()
    manager.beginLiveTranscriptDisplaySession(source: current)
    manager.liveTranscriber(previous, didDetectUtteranceBoundary: "previous utterance")

    XCTAssertNil(
      manager.utteranceBoundaryText,
      "A boundary from a superseded session must not trigger live polish"
    )

    manager.liveTranscriber(current, didDetectUtteranceBoundary: "current utterance")
    XCTAssertEqual(manager.utteranceBoundaryText, "current utterance")
  }

  // MARK: - Display reset

  func testResetLiveTranscriptDisplay_clearsPreviousRecordingText() {
    let manager = self.makeManager()
    let previous = StubLiveController()
    manager.beginLiveTranscriptDisplaySession(source: previous)
    manager.liveTranscriber(previous, didUpdatePartial: "previous")
    manager.endLiveTranscriptDisplaySession()

    manager.resetLiveTranscriptDisplay()

    XCTAssertEqual(manager.liveTranscript, .empty)
    // A batch-mode recording never opens a live session, so nothing may leak in.
    manager.liveTranscriber(previous, didUpdatePartial: "previous")
    XCTAssertEqual(manager.livePartialText, "")
  }

  func testNewSessionMintsDistinctIdentity() {
    let manager = self.makeManager()
    let controller = StubLiveController()

    manager.beginLiveTranscriptDisplaySession(source: controller)
    let first = manager.liveTranscript.sessionID
    manager.endLiveTranscriptDisplaySession()

    manager.beginLiveTranscriptDisplaySession(source: controller)
    let second = manager.liveTranscript.sessionID

    XCTAssertNotNil(first)
    XCTAssertNotNil(second)
    XCTAssertNotEqual(first, second)
  }

  // MARK: - Scope semantics

  func testScopeRejectsUnboundAndSupersededSources() {
    let scope = LiveTranscriptDisplayScope()
    let owner = StubLiveController()
    let other = StubLiveController()

    XCTAssertFalse(scope.accepts(owner), "Nothing is accepted before a session begins")

    scope.begin()
    XCTAssertFalse(scope.accepts(owner), "An unbound session must not adopt the first caller")

    scope.bind(source: owner)
    XCTAssertTrue(scope.accepts(owner))
    XCTAssertFalse(scope.accepts(other))

    scope.unbind()
    XCTAssertFalse(scope.accepts(owner))

    scope.end()
    scope.bind(source: owner)
    XCTAssertFalse(scope.accepts(owner), "Binding must not revive a finished session")
  }

  // MARK: - Production wiring

  /// The switcher is what tells its owner which controller is on air. Without
  /// this notification nothing ever binds the display scope in production.
  func testSwitchingLiveTranscriber_publishesSessionOwnershipChanges() async {
    let switcher = self.makeSwitchingTranscriber()
    // Routes to the "local live streaming unsupported" controller, whose
    // start() throws before touching the microphone or the network.
    let model = "local/whisperkit/tiny"
    let expected = ObjectIdentifier(switcher.controller(for: model))

    var observed: [ObjectIdentifier?] = []
    switcher.sessionSourceDidChange = { source in
      observed.append(source.map(ObjectIdentifier.init))
    }

    switcher.configure(language: nil, model: model)
    try? await switcher.start()
    await switcher.stop()

    XCTAssertEqual(
      observed.first,
      .some(expected),
      "Session start must publish the controller that owns the recording"
    )
    XCTAssertEqual(observed.last, .some(nil), "Stopping must release session ownership")
  }

  /// Drives the real closure `TranscriptionManager` installs on
  /// `sessionSourceDidChange`, rather than the `source:` convenience used by
  /// the other tests, so the production binding path itself is covered.
  func testSessionSourceDidChange_bindsAndReleasesTheDisplayScope() {
    let manager = self.makeManager()
    let controller = StubLiveController()

    manager.beginLiveTranscriptDisplaySession()
    XCTAssertFalse(
      manager.displayScope.accepts(controller),
      "A session with no bound source must not adopt the first caller"
    )
    manager.liveTranscriber(controller, didUpdatePartial: "too early")
    XCTAssertEqual(manager.livePartialText, "")

    manager.liveController.sessionSourceDidChange?(controller)

    XCTAssertTrue(
      manager.displayScope.accepts(controller),
      "The controller published by the switcher must own the display session"
    )
    manager.liveTranscriber(controller, didUpdatePartial: "on air")
    XCTAssertEqual(manager.livePartialText, "on air")

    manager.liveController.sessionSourceDidChange?(nil)

    XCTAssertFalse(manager.displayScope.accepts(controller))
    manager.liveTranscriber(controller, didUpdatePartial: "after release")
    XCTAssertEqual(manager.livePartialText, "on air")
  }

  // MARK: - Per-stream isolation

  /// The display scope keys on the controller instance, and cached controllers
  /// are reused, so a late callback from the previous recording's socket
  /// arrives through a controller the scope legitimately accepts. Only the
  /// per-stream guard can tell the two runs apart.
  func testStaleStreamOnReusedController_isDroppedDuringTheNextSession() {
    let manager = self.makeManager()
    let controller = StreamingStubController()
    controller.delegate = manager

    let firstStream = controller.startStream()
    manager.beginLiveTranscriptDisplaySession(source: controller)
    controller.deliverPartial("first recording", from: firstStream)
    XCTAssertEqual(manager.livePartialText, "first recording")
    manager.endLiveTranscriptDisplaySession()

    // Next recording: same cached controller instance, a brand new stream.
    let secondStream = controller.startStream()
    manager.beginLiveTranscriptDisplaySession(source: controller)
    controller.deliverPartial("second recording", from: secondStream)
    XCTAssertEqual(manager.livePartialText, "second recording")

    XCTAssertTrue(
      manager.displayScope.accepts(controller),
      "The session guard cannot catch this — the stale callback shares the controller"
    )
    controller.deliverPartial("first recording", from: firstStream)

    XCTAssertEqual(
      manager.livePartialText,
      "second recording",
      "A message queued by the previous stream must not repaint the live view"
    )
  }

  func testLiveTranscriptionRun_identifiesSupersededStreams() {
    let active = StubLiveController()
    let superseded = StubLiveController()

    XCTAssertTrue(LiveTranscriptionRun.isCurrent(active, activeStream: active))
    XCTAssertFalse(LiveTranscriptionRun.isCurrent(superseded, activeStream: active))
    XCTAssertFalse(LiveTranscriptionRun.isCurrent(active, activeStream: nil))
    XCTAssertFalse(LiveTranscriptionRun.isCurrent(nil, activeStream: active))
  }
}
