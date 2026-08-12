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

  func testLiveTranscriptionRun_identifiesSupersededStreams() {
    let active = StubLiveController()
    let superseded = StubLiveController()

    XCTAssertTrue(LiveTranscriptionRun.isCurrent(active, activeStream: active))
    XCTAssertFalse(LiveTranscriptionRun.isCurrent(superseded, activeStream: active))
    XCTAssertFalse(LiveTranscriptionRun.isCurrent(active, activeStream: nil))
    XCTAssertFalse(LiveTranscriptionRun.isCurrent(nil, activeStream: active))
  }
}
