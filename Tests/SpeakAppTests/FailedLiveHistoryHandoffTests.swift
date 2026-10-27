import Foundation
import SpeakCore
import XCTest
@testable import SpeakApp

@MainActor
final class FailedLiveHistoryHandoffTests: XCTestCase {
  private enum ProviderFailure: LocalizedError, Equatable {
    case stopped
    var errorDescription: String? { "Synthetic provider failure" }
  }

  private final class Controller: LiveTranscriptionController {
    weak var delegate: LiveTranscriptionSessionDelegate?
    private(set) var isRunning = false
    var finalText = " Owned confirmed tail and draft \n"

    func configure(language: String?, model: String) {}
    func start() async throws { isRunning = true }
    func stop() async {
      isRunning = false
      delegate?.liveTranscriber(self, didUpdatePartial: finalText)
      delegate?.liveTranscriber(self, didFail: ProviderFailure.stopped)
      delegate?.liveTranscriber(self, didFinishWith: Self.result("Ignored success after failure"))
    }

    static func result(_ text: String) -> TranscriptionResult {
      TranscriptionResult(
        text: text, segments: [], confidence: nil, duration: 1,
        modelIdentifier: "deepgram/nova-3-streaming", cost: nil, rawPayload: nil, debugInfo: nil
      )
    }
  }

  func testFailedProviderOrderRetainsRawHistoryBeforeDisplayResetWithoutSuccessMetadata() async throws {
    let controller = Controller()
    let manager = makeManager(controller)
    try await manager.startLiveTranscription()
    let session = makeSession(token: manager.liveTranscript.sessionID)
    let error = await stopError(manager)
    XCTAssertEqual(error as? ProviderFailure, .stopped)
    XCTAssertNil(session.transcriptionResult, "A throwing stop must not become a successful provider result")
    session.errors.append(HistoryError(phase: .transcription, message: "Processing failed",
                                       debugDescription: error?.localizedDescription))
    session.retainFailedLiveTranscript(manager.liveTranscript, policy: .retainOwned, mayTearDownCapture: true)
    manager.cancelLiveTranscription()
    XCTAssertEqual(manager.liveTranscript, .empty)

    let history = session.buildHistoryItem(finalText: nil)
    XCTAssertEqual(history.rawTranscription, controller.finalText)
    XCTAssertEqual(history.errors.first?.debugDescription, ProviderFailure.stopped.localizedDescription)
    XCTAssertEqual(history.audioFileURL, session.recordingSummary?.url)
    XCTAssertEqual(history.recordingDuration, 3)
    XCTAssertNil(history.postProcessedTranscription)
    XCTAssertNil(history.cost)
    XCTAssertTrue(history.modelUsages.isEmpty)
    XCTAssertNil(history.phaseTimestamps.transcriptionEnded)
  }

  func testFrozenFailedSessionCannotReadReplacementRunsTextDuringDelayedHistoryAppend() async throws {
    let controller = Controller()
    let manager = makeManager(controller)
    try await manager.startLiveTranscription()
    let failed = makeSession(token: manager.liveTranscript.sessionID)
    _ = await stopError(manager)
    failed.retainFailedLiveTranscript(manager.liveTranscript, policy: .retainOwned, mayTearDownCapture: true)
    let savedText = controller.finalText
    manager.cancelLiveTranscription()
    try await manager.startLiveTranscription()
    defer { manager.cancelLiveTranscription() }
    manager.liveTranscriber(controller, didUpdatePartial: "Replacement recording private words")
    failed.retainFailedLiveTranscript(manager.liveTranscript, policy: .retainOwned, mayTearDownCapture: true)
    XCTAssertEqual(failed.buildHistoryItem(finalText: nil).rawTranscription, savedText)
  }

  func testUnboundOrDifferentRunCannotAcquireSharedDisplayText() async throws {
    let controller = Controller()
    let manager = makeManager(controller)
    try await manager.startLiveTranscription()
    defer { manager.cancelLiveTranscription() }
    manager.liveTranscriber(controller, didUpdatePartial: "Current run")
    for token in [nil, LiveTranscriptSessionID()] as [LiveTranscriptSessionID?] {
      let session = makeSession(token: token)
      session.retainFailedLiveTranscript(manager.liveTranscript, policy: .retainOwned, mayTearDownCapture: true)
      XCTAssertNil(session.buildHistoryItem(finalText: nil).rawTranscription)
    }
  }

  func testExplicitCancellationDiscardsFallbackEvenWithMatchingToken() async throws {
    let controller = Controller()
    let manager = makeManager(controller)
    try await manager.startLiveTranscription()
    let session = makeSession(token: manager.liveTranscript.sessionID)
    manager.liveTranscriber(controller, didUpdatePartial: "Cancelled private words")
    let snapshot = manager.liveTranscript
    session.retainFailedLiveTranscript(snapshot, policy: .retainOwned, mayTearDownCapture: true)
    session.retainFailedLiveTranscript(snapshot, policy: .discard, mayTearDownCapture: true)
    manager.cancelLiveTranscription()
    XCTAssertNil(session.buildHistoryItem(finalText: nil).rawTranscription)
    XCTAssertEqual(manager.liveTranscript, .empty)
  }

  func testVoiceEditOwnershipAndStaleSourceCannotSupplyFailureText() async throws {
    let controller = Controller()
    let manager = makeManager(controller)
    try await manager.startLiveTranscription()
    defer { manager.cancelLiveTranscription() }
    let session = makeSession(token: manager.liveTranscript.sessionID)
    manager.liveTranscriber(Controller(), didUpdatePartial: "Stale controller text")
    XCTAssertTrue(manager.liveTranscript.text.isEmpty)
    manager.liveTranscriber(controller, didUpdatePartial: "Unrelated shared display")
    let ownership = CaptureSessionOwnership()
    XCTAssertTrue(ownership.reserve(.voiceEdit))
    session.retainFailedLiveTranscript(
      manager.liveTranscript, policy: .retainOwned,
      mayTearDownCapture: ownership.mayTearDownCapture(.dictation)
    )
    XCTAssertNil(session.buildHistoryItem(finalText: nil).rawTranscription)
    XCTAssertTrue(manager.isLiveTranscribing, "Rejecting salvage must not tear down another owner's stream")
  }

  func testGenuineResultIncludingEmptyTextAlwaysWinsAndBlankPartialIsNotInvented() {
    let token = LiveTranscriptSessionID()
    let partial = LiveTranscriptSnapshot(sessionID: token, text: "partial", isFinal: false, confidence: nil)
    for text in ["Genuine result", ""] {
      let session = makeSession(token: token)
      session.retainFailedLiveTranscript(partial, policy: .retainOwned, mayTearDownCapture: true)
      session.transcriptionResult = Controller.result(text)
      XCTAssertEqual(session.buildHistoryItem(finalText: nil).rawTranscription, text)
    }
    let session = makeSession(token: token)
    session.retainFailedLiveTranscript(
      LiveTranscriptSnapshot(sessionID: token, text: " \n\t", isFinal: false, confidence: nil),
      policy: .retainOwned, mayTearDownCapture: true
    )
    XCTAssertNil(session.buildHistoryItem(finalText: nil).rawTranscription)
  }

  private func stopError(_ manager: TranscriptionManager) async -> Error? {
    let settled = expectation(description: "Original stop failure settled")
    let task = Task { @MainActor () -> Error? in
      defer { settled.fulfill() }
      do {
        _ = try await manager.stopLiveTranscription()
        XCTFail("Provider failure must still throw")
        return nil
      } catch { return error }
    }
    guard await XCTWaiter.fulfillment(of: [settled], timeout: 2) == .completed else {
      task.cancel()
      manager.cancelLiveTranscription()
      XCTFail("Failure handoff did not settle its owned stop")
      return nil
    }
    return await task.value
  }

  private func makeSession(token: LiveTranscriptSessionID?) -> ActiveSession {
    let session = ActiveSession(gesture: .uiButton, hotKeyDescription: "Synthetic")
    session.liveTranscriptSessionID = token
    session.recordingSummary = RecordingSummary(
      id: UUID(), url: URL(fileURLWithPath: "/synthetic/retained-audio.m4a"),
      startedAt: session.recordingStarted, duration: 3, fileSize: 12
    )
    return session
  }

  private func makeManager(_ controller: Controller) -> TranscriptionManager {
    let suite = "FailedLiveHistoryHandoffTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.transcriptionMode = .liveNative
    settings.liveTranscriptionModel = "deepgram/nova-3-streaming"
    let permissions = PermissionsManager()
    let devices = AudioInputDeviceManager(appSettings: settings)
    let storage = SecureAppStorage(permissionsManager: permissions, appSettings: settings, keychainService: suite)
    let openRouter = OpenRouterAPIClient(secureStorage: storage)
    return TranscriptionManager(
      appSettings: settings, permissionsManager: permissions, audioDeviceManager: devices,
      batchClient: RemoteAudioTranscriber(client: openRouter), openRouter: openRouter, secureStorage: storage,
      controllerOverride: { _ in controller }
    )
  }
}
