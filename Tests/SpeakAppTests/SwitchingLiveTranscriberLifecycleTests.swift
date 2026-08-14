import SpeakCore
import XCTest

@testable import SpeakApp

@MainActor
final class SwitchingLiveTranscriberLifecycleTests: XCTestCase {
  private final class SlowStopController: LiveTranscriptionController {
    weak var delegate: LiveTranscriptionSessionDelegate?
    private(set) var isRunning = false
    private(set) var startCount = 0
    private(set) var stopCount = 0
    var stopStarted: (() -> Void)?
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private var shouldSuspendStop = true

    func configure(language: String?, model: String) {}

    func start() async throws {
      startCount += 1
      isRunning = true
    }

    func stop() async {
      stopCount += 1
      if shouldSuspendStop {
        shouldSuspendStop = false
        stopStarted?()
        await withCheckedContinuation { continuation in
          stopContinuation = continuation
        }
      }
      isRunning = false
    }

    func completeStop() {
      stopContinuation?.resume()
      stopContinuation = nil
    }
  }

  func testOldAsynchronousStop_cannotClearOrOverlapReplacementRun() async throws {
    let controller = SlowStopController()
    let switcher = makeSwitcher(controller: controller)
    let stopStarted = expectation(description: "old controller stop started")
    controller.stopStarted = { stopStarted.fulfill() }

    try await switcher.start()
    switcher.scheduleStop()
    await fulfillment(of: [stopStarted], timeout: 2)

    let replacementStart = Task { try await switcher.start() }
    await Task.yield()
    XCTAssertEqual(controller.startCount, 1, "Replacement must wait for the cached controller's old stop")

    controller.completeStop()
    try await replacementStart.value

    XCTAssertTrue(switcher.isRunning, "The old stop must not clear ownership of the replacement run")
    XCTAssertEqual(controller.startCount, 2)
    await switcher.stop()
    XCTAssertEqual(controller.stopCount, 2, "The replacement controller must remain reachable for teardown")
  }

  private func makeSwitcher(controller: any LiveTranscriptionController) -> SwitchingLiveTranscriber {
    let settings = AppSettings()
    let permissions = PermissionsManager()
    let audioDevices = AudioInputDeviceManager(appSettings: settings)
    let secureStorage = SecureAppStorage(
      permissionsManager: permissions,
      appSettings: settings,
      keychainService: "com.justspeaktoit.tests.switcher-lifecycle.\(UUID().uuidString)"
    )
    return SwitchingLiveTranscriber(
      appSettings: settings,
      permissionsManager: permissions,
      audioDeviceManager: audioDevices,
      secureStorage: secureStorage,
      controllerOverride: { _ in controller }
    )
  }
}
