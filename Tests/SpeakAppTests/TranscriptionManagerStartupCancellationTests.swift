import SpeakCore
import XCTest

@testable import SpeakApp

@MainActor
final class TranscriptionStartupCancellationTests: XCTestCase {
  /// Models providers that acquire capture only after a permission/device await,
  /// and cannot interrupt that await even when their task has been cancelled.
  private final class SuspendedStartController: LiveTranscriptionController {
    weak var delegate: LiveTranscriptionSessionDelegate?
    private(set) var isRunning = false
    private(set) var stopCount = 0
    var suspendStart = true
    var releaseStartupOnStop = false
    var onStart: (() -> Void)?
    var onStartCancelled: (@Sendable () -> Void)?
    var onStop: (() -> Void)?
    private var startContinuation: CheckedContinuation<Void, Never>?

    func configure(language: String?, model: String) {}

    func start() async throws {
      self.onStart?()
      if self.suspendStart {
        let onCancelled = self.onStartCancelled
        await withTaskCancellationHandler {
          await withCheckedContinuation { self.startContinuation = $0 }
        } onCancel: {
          onCancelled?()
        }
      }
      // Deliberately ignore cancellation, like a platform API completing late.
      self.isRunning = true
    }

    func releaseStart() {
      self.startContinuation?.resume()
      self.startContinuation = nil
    }

    func stop() async {
      if self.releaseStartupOnStop { self.releaseStart() }
      guard self.isRunning else { return }
      self.stopCount += 1
      self.onStop?()
      self.isRunning = false
      self.delegate?.liveTranscriber(self, didFinishWith: TranscriptionResult(
        text: "new recording",
        segments: [],
        confidence: nil,
        duration: 1,
        modelIdentifier: "deepgram/nova-3-streaming",
        cost: nil,
        rawPayload: nil,
        debugInfo: nil
      ))
    }
  }

  func testCancelDuringStartup_retiresLateCaptureBeforeAllowingReplacement() async throws {
    let controller = SuspendedStartController()
    let manager = self.makeManager(controller: controller)
    let started = self.expectation(description: "provider awaiting startup")
    let cancelled = self.expectation(description: "provider startup task cancelled")
    controller.onStart = { started.fulfill() }
    controller.onStartCancelled = { cancelled.fulfill() }
    let startup = Task { try await manager.startLiveTranscription() }
    await self.fulfillment(of: [started], timeout: 2)

    manager.cancelLiveTranscription()
    await self.fulfillment(of: [cancelled], timeout: 2)
    // A broken implementation must fail this assertion without suspending a
    // second startup and preventing the test from releasing the first.
    controller.suspendStart = false
    do {
      try await manager.startLiveTranscription()
      XCTFail("A replacement must not overlap startup that still owns capture")
    } catch {
      XCTAssertEqual(error as? TranscriptionManagerError, .liveSessionAlreadyRunning)
    }

    controller.releaseStart()
    do {
      try await startup.value
      XCTFail("Cancelled startup must not report a running session")
    } catch {
      XCTAssertTrue(error is CancellationError)
    }
    XCTAssertFalse(controller.isRunning, "Late capture must be stopped before releasing ownership")
    XCTAssertFalse(manager.liveController.isRunning)
    XCTAssertFalse(manager.isLiveTranscribing)
    XCTAssertEqual(controller.stopCount, 1, "Concurrent teardown requests must stop capture only once")
    XCTAssertEqual(manager.liveTranscript, .empty)

    controller.suspendStart = false
    controller.onStart = nil
    controller.onStartCancelled = nil
    try await manager.startLiveTranscription()
    let result = try await manager.stopLiveTranscription()
    XCTAssertEqual(result.text, "new recording")
    XCTAssertEqual(controller.stopCount, 2)
  }

  func testCancellingStartupCaller_propagatesAndReleasesLateCapture() async throws {
    let controller = SuspendedStartController()
    let manager = self.makeManager(controller: controller)
    let started = self.expectation(description: "provider awaiting startup")
    let cancelled = self.expectation(description: "caller cancellation reaches provider")
    controller.onStart = { started.fulfill() }
    controller.onStartCancelled = { cancelled.fulfill() }
    let startup = Task { try await manager.startLiveTranscription() }
    await self.fulfillment(of: [started], timeout: 2)

    startup.cancel()
    await self.fulfillment(of: [cancelled], timeout: 2)
    controller.releaseStart()
    do {
      try await startup.value
      XCTFail("Caller cancellation must survive a provider returning success")
    } catch {
      XCTAssertTrue(error is CancellationError)
    }

    XCTAssertFalse(controller.isRunning)
    XCTAssertFalse(manager.isLiveTranscribing)
    XCTAssertFalse(manager.displayScope.isActive)
    XCTAssertEqual(controller.stopCount, 1)
  }

  func testCancelWhenProviderNeedsStopToFinishStartup_doesNotDeadlock() async {
    let controller = SuspendedStartController()
    controller.releaseStartupOnStop = true
    let manager = self.makeManager(controller: controller)
    let started = self.expectation(description: "provider awaiting stop to finish startup")
    let completed = self.expectation(description: "startup cancellation completes")
    controller.onStart = { started.fulfill() }
    Task { @MainActor in
      defer { completed.fulfill() }
      do {
        try await manager.startLiveTranscription()
        XCTFail("Cancelled startup must not report success")
      } catch {
        XCTAssertTrue(error is CancellationError)
      }
    }
    await self.fulfillment(of: [started], timeout: 2)

    manager.cancelLiveTranscription()
    await self.fulfillment(of: [completed], timeout: 2)

    XCTAssertFalse(controller.isRunning)
    XCTAssertFalse(manager.isLiveTranscribing)
    XCTAssertEqual(controller.stopCount, 1)
  }

  func testCallerCancellationWhenProviderNeedsStopToFinishStartup_doesNotDeadlock() async {
    let controller = SuspendedStartController()
    controller.releaseStartupOnStop = true
    let manager = self.makeManager(controller: controller)
    let started = self.expectation(description: "provider awaiting stop to finish startup")
    let completed = self.expectation(description: "caller cancellation completes")
    controller.onStart = { started.fulfill() }
    let startup = Task { @MainActor in
      defer { completed.fulfill() }
      do {
        try await manager.startLiveTranscription()
        XCTFail("Cancelled startup must not report success")
      } catch {
        XCTAssertTrue(error is CancellationError)
      }
    }
    await self.fulfillment(of: [started], timeout: 2)

    startup.cancel()
    await self.fulfillment(of: [completed], timeout: 2)

    XCTAssertFalse(controller.isRunning)
    XCTAssertFalse(manager.isLiveTranscribing)
    XCTAssertEqual(controller.stopCount, 1)
  }

  func testNormalStop_keepsSourceBoundUntilProviderFinishes() async throws {
    let controller = SuspendedStartController()
    controller.suspendStart = false
    let manager = self.makeManager(controller: controller)
    try await manager.startLiveTranscription()
    defer { controller.onStop = nil }
    controller.onStop = {
      XCTAssertTrue(manager.displayScope.accepts(controller))
    }

    let result = try await manager.stopLiveTranscription()
    // Wait for the switcher's teardown, which can finish after the manager's
    // continuation resumes but must never unbind before the terminal callback.
    await manager.liveController.stop()

    XCTAssertEqual(result.text, "new recording")
    XCTAssertEqual(manager.livePartialText, "new recording")
    XCTAssertFalse(manager.displayScope.isActive)
    XCTAssertFalse(manager.liveController.isRunning)
  }

  private func makeManager(controller: any LiveTranscriptionController) -> TranscriptionManager {
    let suiteName = "com.justspeaktoit.tests.startup-cancellation.\(UUID().uuidString)"
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
      keychainService: suiteName
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
