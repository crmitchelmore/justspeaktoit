import SpeakCore
import XCTest

@testable import SpeakApp

@MainActor
final class TranscriptionManagerLifecycleTests: XCTestCase {
  private enum StubError: Error, Equatable {
    case staleProvider
    case startupFailure
  }

  private final class StubController: LiveTranscriptionController {
    weak var delegate: LiveTranscriptionSessionDelegate?
    private(set) var isRunning = false
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?
    var suspendStop = false
    private var stopContinuation: CheckedContinuation<Void, Never>?

    func configure(language: String?, model: String) {}

    func start() async throws {
      self.isRunning = true
      self.onStart?()
    }

    func stop() async {
      self.onStop?()
      if self.suspendStop {
        await withCheckedContinuation { self.stopContinuation = $0 }
      }
      self.isRunning = false
      self.delegate?.liveTranscriber(self, didFinishWith: Self.result("current recording"))
    }

    func releaseStop() {
      self.stopContinuation?.resume()
      self.stopContinuation = nil
    }

    static func result(_ text: String) -> TranscriptionResult {
      TranscriptionResult(
        text: text,
        segments: [],
        confidence: nil,
        duration: 1,
        modelIdentifier: "deepgram/nova-3-streaming",
        cost: nil,
        rawPayload: nil,
        debugInfo: nil
      )
    }
  }

  func testStaleFinishDuringStop_doesNotConsumeCurrentResult() async throws {
    let current = StubController()
    let stale = StubController()
    let manager = self.makeManager(controller: current)
    try await manager.startLiveTranscription()
    defer { current.onStop = nil }
    current.onStop = {
      manager.liveTranscriber(stale, didFinishWith: StubController.result("old recording"))
      XCTAssertTrue(manager.isLiveTranscribing)
    }

    let result = try await manager.stopLiveTranscription()

    XCTAssertEqual(result.text, "current recording")
    XCTAssertEqual(manager.livePartialText, "current recording")
    XCTAssertFalse(manager.isLiveTranscribing)
  }

  func testStaleFailureDuringStop_doesNotFailCurrentResult() async throws {
    let current = StubController()
    let stale = StubController()
    let manager = self.makeManager(controller: current)
    try await manager.startLiveTranscription()
    defer { current.onStop = nil }
    current.onStop = {
      manager.liveTranscriber(stale, didFail: StubError.staleProvider)
      XCTAssertTrue(manager.isLiveTranscribing)
    }

    let result = try await manager.stopLiveTranscription()

    XCTAssertEqual(result.text, "current recording")
    XCTAssertEqual(manager.livePartialText, "current recording")
  }

  func testStaleFailureWhileRecording_doesNotPoisonNextStop() async throws {
    let current = StubController()
    let manager = self.makeManager(controller: current)
    try await manager.startLiveTranscription()
    manager.liveTranscriber(StubController(), didFail: StubError.staleProvider)

    let result = try await manager.stopLiveTranscription()

    XCTAssertEqual(result.text, "current recording")
  }

  func testFailureDuringStartup_isPreservedUntilStop() async throws {
    let current = StubController()
    let manager = self.makeManager(controller: current)
    defer { current.onStart = nil }
    current.onStart = {
      current.delegate?.liveTranscriber(current, didFail: StubError.startupFailure)
    }
    try await manager.startLiveTranscription()

    do {
      _ = try await manager.stopLiveTranscription()
      XCTFail("The provider failure during startup must not be erased")
    } catch {
      XCTAssertEqual(error as? StubError, .startupFailure)
    }
  }

  func testFailureAfterCancellation_doesNotRevivePendingError() async throws {
    let current = StubController()
    let manager = self.makeManager(controller: current)
    try await manager.startLiveTranscription()
    manager.liveTranscriber(current, didFail: StubError.startupFailure)
    manager.cancelLiveTranscription()
    manager.liveTranscriber(current, didFail: StubError.staleProvider)

    do {
      _ = try await manager.stopLiveTranscription()
      XCTFail("Cancelled sessions are no longer running")
    } catch {
      XCTAssertEqual(error as? TranscriptionManagerError, .liveSessionNotRunning)
    }
  }

  func testConcurrentStop_rejectsSecondCallerAndCompletesFirst() async throws {
    let current = StubController()
    current.suspendStop = true
    let manager = self.makeManager(controller: current)
    let stopStarted = self.expectation(description: "controller is stopping")
    let firstCompleted = self.expectation(description: "first stop keeps its continuation")
    let secondRejected = self.expectation(description: "second stop rejects immediately")
    current.onStop = { stopStarted.fulfill() }
    try await manager.startLiveTranscription()

    Task { @MainActor in
      defer { firstCompleted.fulfill() }
      do {
        let result = try await manager.stopLiveTranscription()
        XCTAssertEqual(result.text, "current recording")
      } catch {
        XCTFail("First stop unexpectedly failed: \(error)")
      }
    }
    await self.fulfillment(of: [stopStarted], timeout: 2)
    Task { @MainActor in
      defer { secondRejected.fulfill() }
      do {
        _ = try await manager.stopLiveTranscription()
        XCTFail("A second stop must not replace the first continuation")
      } catch {
        XCTAssertEqual(error as? TranscriptionManagerError, .liveSessionAlreadyStopping)
      }
    }
    await self.fulfillment(of: [secondRejected], timeout: 2)
    current.releaseStop()
    await self.fulfillment(of: [firstCompleted], timeout: 2)
    XCTAssertFalse(manager.isLiveTranscribing)
  }

  private func makeManager(controller: any LiveTranscriptionController) -> TranscriptionManager {
    let suiteName = "com.justspeaktoit.tests.manager-lifecycle.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    self.addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
    let settings = AppSettings(defaults: defaults)
    settings.transcriptionMode = .liveNative
    settings.liveTranscriptionModel = "deepgram/nova-3-streaming"
    let permissions = PermissionsManager()
    let audioDevices = AudioInputDeviceManager(appSettings: settings)
    let secureStorage = SecureAppStorage(
      permissionsManager: permissions,
      appSettings: settings,
      keychainService: "com.justspeaktoit.tests.manager-lifecycle.\(UUID().uuidString)"
    )
    let openRouter = OpenRouterAPIClient(secureStorage: secureStorage)
    return TranscriptionManager(
      appSettings: settings,
      permissionsManager: permissions,
      audioDeviceManager: audioDevices,
      batchClient: RemoteAudioTranscriber(client: openRouter),
      openRouter: openRouter,
      secureStorage: secureStorage,
      controllerOverride: { _ in controller }
    )
  }
}
