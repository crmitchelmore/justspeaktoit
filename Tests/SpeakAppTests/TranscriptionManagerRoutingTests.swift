import SpeakCore
import XCTest

@testable import SpeakApp

final class TranscriptionManagerRoutingTests: XCTestCase {
  func testResolvedLiveTranscriptionModel_usesLiveModelOutsideLocalStreaming() throws {
    let model = try TranscriptionManager.resolvedLiveTranscriptionModel(
      transcriptionMode: .liveNative,
      localTranscriptionMode: .streaming,
      localStreamingModelSource: "",
      liveTranscriptionModel: "deepgram/nova-3-streaming",
      availableStreamingSourceIDs: []
    )

    XCTAssertEqual(model, "deepgram/nova-3-streaming")
  }

  func testResolvedLiveTranscriptionModel_returnsValidLocalStreamingSource() throws {
    let sourceID = "local/streaming/example"
    let model = try TranscriptionManager.resolvedLiveTranscriptionModel(
      transcriptionMode: .localModel,
      localTranscriptionMode: .streaming,
      localStreamingModelSource: sourceID,
      liveTranscriptionModel: "apple/local/SFSpeechRecognizer",
      availableStreamingSourceIDs: [sourceID]
    )

    XCTAssertEqual(model, sourceID)
  }

  @MainActor
  func testSwitchingLiveTranscriber_routesFluidAudioParakeetToDedicatedController() {
    let settings = AppSettings()
    let permissions = PermissionsManager()
    let audioDevices = AudioInputDeviceManager(appSettings: settings)
    let secureStorage = SecureAppStorage(
      permissionsManager: permissions,
      appSettings: settings,
      keychainService: "com.justspeaktoit.tests.fluidaudio.routing.\(UUID().uuidString)"
    )
    let transcriber = SwitchingLiveTranscriber(
      appSettings: settings,
      permissionsManager: permissions,
      audioDeviceManager: audioDevices,
      secureStorage: secureStorage
    )

    XCTAssertTrue(
      transcriber.controller(for: FluidAudioParakeetModel.id) is FluidAudioParakeetLiveController
    )
  }

  @MainActor
  func testSwitchingLiveTranscriber_routesWhisperKitStreamingToDedicatedController() {
    XCTAssertEqual(
      WhisperKitStreamingModel.id(forBatchModelID: "local/whisperkit/tiny"),
      "local/streaming/whisperkit/tiny"
    )

    let settings = AppSettings()
    let permissions = PermissionsManager()
    let audioDevices = AudioInputDeviceManager(appSettings: settings)
    let secureStorage = SecureAppStorage(
      permissionsManager: permissions,
      appSettings: settings,
      keychainService: "com.justspeaktoit.tests.whisperkit.routing.\(UUID().uuidString)"
    )
    let transcriber = SwitchingLiveTranscriber(
      appSettings: settings,
      permissionsManager: permissions,
      audioDeviceManager: audioDevices,
      secureStorage: secureStorage
    )

    XCTAssertTrue(
      transcriber.controller(for: "local/streaming/whisperkit/tiny") is WhisperKitLiveController
    )
  }

  /// Record-start prepares a live input engine only for routes that claim it;
  /// WhisperKit captures through its own `AudioStreamTranscriber`.
  @MainActor
  func testSwitchingLiveTranscriber_preparesTheLiveInputEngineOnlyForRoutesThatUseIt() {
    let settings = AppSettings()
    let permissions = PermissionsManager()
    let audioDevices = AudioInputDeviceManager(appSettings: settings)
    let secureStorage = SecureAppStorage(
      permissionsManager: permissions,
      appSettings: settings,
      keychainService: "com.justspeaktoit.tests.liveinput.routing.\(UUID().uuidString)"
    )
    let transcriber = SwitchingLiveTranscriber(
      appSettings: settings,
      permissionsManager: permissions,
      audioDeviceManager: audioDevices,
      secureStorage: secureStorage
    )

    XCTAssertFalse(transcriber.usesLiveInputEngine(for: "local/streaming/whisperkit/tiny"))
    for model in [
      "deepgram/nova-3-streaming",
      "assemblyai/universal-streaming",
      "openai/gpt-live-transcribe",
      "xai/grok-voice-transcribe-2.0",
      AppleLocalModels.speechTranscriberModelID,
      AppleLocalModels.legacySpeechModelID,
      FluidAudioParakeetModel.id
    ] {
      XCTAssertTrue(transcriber.usesLiveInputEngine(for: model), model)
    }
  }

  @MainActor
  func testSwitchingLiveTranscriber_routesSpeechAnalyzerModelsToAnalyzerController() {
    let settings = AppSettings()
    let permissions = PermissionsManager()
    let audioDevices = AudioInputDeviceManager(appSettings: settings)
    let secureStorage = SecureAppStorage(
      permissionsManager: permissions,
      appSettings: settings,
      keychainService: "com.justspeaktoit.tests.speechanalyzer.routing.\(UUID().uuidString)"
    )
    let transcriber = SwitchingLiveTranscriber(
      appSettings: settings,
      permissionsManager: permissions,
      audioDeviceManager: audioDevices,
      secureStorage: secureStorage
    )

    XCTAssertTrue(
      transcriber.controller(for: AppleLocalModels.speechTranscriberModelID)
        is AppleSpeechAnalyzerLiveController
    )
    XCTAssertTrue(
      transcriber.controller(for: AppleLocalModels.dictationTranscriberModelID)
        is AppleSpeechAnalyzerLiveController
    )
    // The legacy engine and the system-dictation alias stay on the native path.
    XCTAssertTrue(
      transcriber.controller(for: AppleLocalModels.legacySpeechModelID)
        is NativeOSXLiveTranscriber
    )
    XCTAssertTrue(
      transcriber.controller(for: "apple/local/Dictation") is NativeOSXLiveTranscriber
    )
  }

  func testResolvedLiveTranscriptionModel_rejectsInvalidLocalStreamingSource() {
    XCTAssertThrowsError(
      try TranscriptionManager.resolvedLiveTranscriptionModel(
        transcriptionMode: .localModel,
        localTranscriptionMode: .streaming,
        localStreamingModelSource: "",
        liveTranscriptionModel: "apple/local/SFSpeechRecognizer",
        availableStreamingSourceIDs: []
      )
    ) { error in
      XCTAssertEqual(
        error as? TranscriptionManagerError,
        .invalidLocalStreamingSource("")
      )
    }
  }
}
