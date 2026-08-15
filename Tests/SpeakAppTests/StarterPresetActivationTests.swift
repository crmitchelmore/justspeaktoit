import SpeakCore
@testable import SpeakApp
import XCTest

final class StarterPresetActivationTests: XCTestCase {
  private var suiteNames: [String] = []

  override func tearDown() {
    for suiteName in suiteNames {
      UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }
    suiteNames = []
    super.tearDown()
  }

  @MainActor
  func testFailedDownload_keepsThePreviousSetupActive() async {
    let settings = makeSettings(activeModel: "local/whisperkit/small")

    let activation = StarterPresetActivation.configureAndDownload(
      isReady: false,
      supersedes: nil,
      prepare: { false },
      activate: { self.batchPreset(modelID: "local/whisperkit/large-v3-turbo").activate(in: settings) }
    )
    await activation?.value

    XCTAssertEqual(settings.transcriptionMode, .liveNative)
    XCTAssertEqual(settings.localTranscriptionModel, "local/whisperkit/small")
  }

  @MainActor
  func testSuccessfulDownload_activatesThePresetOnce() async {
    let settings = makeSettings(activeModel: "local/whisperkit/small")
    var activationCount = 0

    let activation = StarterPresetActivation.configureAndDownload(
      isReady: false,
      supersedes: nil,
      prepare: { true },
      activate: {
        activationCount += 1
        self.batchPreset(modelID: "local/whisperkit/large-v3-turbo").activate(in: settings)
      }
    )
    await activation?.value

    XCTAssertEqual(activationCount, 1)
    XCTAssertEqual(settings.transcriptionMode, .localModel)
    XCTAssertEqual(settings.localTranscriptionMode, .batch)
    XCTAssertEqual(settings.localTranscriptionModel, "local/whisperkit/large-v3-turbo")
  }

  @MainActor
  func testInstalledPreset_activatesWithoutADownload() async {
    let settings = makeSettings(activeModel: "local/whisperkit/small")
    var didPrepare = false

    let activation = StarterPresetActivation.configureAndDownload(
      isReady: true,
      supersedes: nil,
      prepare: {
        didPrepare = true
        return true
      },
      activate: { self.batchPreset(modelID: "local/whisperkit/large-v3-turbo").activate(in: settings) }
    )

    XCTAssertNil(activation)
    XCTAssertFalse(didPrepare)
    XCTAssertEqual(settings.localTranscriptionModel, "local/whisperkit/large-v3-turbo")
  }

  @MainActor
  func testCancelledDownload_leavesTheActiveSetupUnchanged() async {
    let settings = makeSettings(activeModel: "local/whisperkit/small")
    let gate = ActivationGate()

    let activation = StarterPresetActivation.configureAndDownload(
      isReady: false,
      supersedes: nil,
      prepare: {
        await gate.wait()
        return true
      },
      activate: { self.batchPreset(modelID: "local/whisperkit/large-v3-turbo").activate(in: settings) }
    )
    activation?.cancel()
    gate.open()
    await activation?.value

    XCTAssertEqual(settings.transcriptionMode, .liveNative)
    XCTAssertEqual(settings.localTranscriptionModel, "local/whisperkit/small")
  }

  @MainActor
  func testOverlappingRequests_letOnlyTheNewestChoiceBecomeActive() async {
    let settings = makeSettings(activeModel: "local/whisperkit/small")
    let gate = ActivationGate()

    let firstActivation = StarterPresetActivation.configureAndDownload(
      isReady: false,
      supersedes: nil,
      prepare: {
        await gate.wait()
        return true
      },
      activate: { self.batchPreset(modelID: "local/whisperkit/tiny").activate(in: settings) }
    )
    let secondActivation = StarterPresetActivation.configureAndDownload(
      isReady: false,
      supersedes: firstActivation,
      prepare: { true },
      activate: { self.batchPreset(modelID: "local/whisperkit/large-v3-turbo").activate(in: settings) }
    )
    await secondActivation?.value
    gate.open()
    await firstActivation?.value

    XCTAssertEqual(settings.localTranscriptionModel, "local/whisperkit/large-v3-turbo")
  }

  // MARK: - Helpers

  @MainActor
  private func makeSettings(activeModel: String) -> AppSettings {
    let suiteName = "com.speakapp.tests.starterPreset.\(UUID().uuidString)"
    suiteNames.append(suiteName)
    let settings = AppSettings(defaults: UserDefaults(suiteName: suiteName)!)
    settings.transcriptionMode = .liveNative
    settings.localTranscriptionModel = activeModel
    return settings
  }

  private func batchPreset(modelID: String) -> LocalTranscriptionStarterPreset {
    LocalTranscriptionStarterPreset(
      id: .whisperKitBatch,
      mode: .batch,
      engine: .whisperKit(
        LocalTranscriptionModel(
          id: modelID,
          displayName: "Test Model",
          modelName: "test-model",
          engine: .whisperKit,
          approximateSizeMB: 200,
          description: "A model for tests.",
          tags: [.quality],
          supportsLiveStreaming: false
        )
      ),
      recommendation: "Best quality for finished recordings",
      detail: "A model for tests.",
      runtime: "WhisperKit / Core ML",
      approximateSizeMB: 200
    )
  }
}

/// Holds a simulated download open until the test releases it.
@MainActor
private final class ActivationGate {
  private var continuation: CheckedContinuation<Void, Never>?
  private var isOpen = false

  func wait() async {
    guard !isOpen else { return }
    await withCheckedContinuation { continuation in
      self.continuation = continuation
    }
  }

  func open() {
    isOpen = true
    continuation?.resume()
    continuation = nil
  }
}
