import SpeakCore
import XCTest

@testable import SpeakApp

final class MetaMuseTranscriptionProviderTests: XCTestCase {
  func testRegistryIncludesMetaBatchProvider() async {
    let provider = await TranscriptionProviderRegistry.shared.provider(withID: "meta")

    XCTAssertEqual(provider?.metadata.displayName, "Meta")
    XCTAssertEqual(provider?.metadata.apiKeyIdentifier, "meta.apiKey")
    XCTAssertEqual(provider?.supportedModels().map(\.id), [MetaMuseVoiceTranscribe.batchCatalogID])
  }

  /// Without this route the Meta streaming model silently falls through to the
  /// Apple on-device controller, so live Muse transcription never runs.
  @MainActor
  func testSwitchingLiveTranscriber_routesMetaToTheSharedClientController() {
    let settings = AppSettings()
    let permissions = PermissionsManager()
    let audioDevices = AudioInputDeviceManager(appSettings: settings)
    let secureStorage = SecureAppStorage(
      permissionsManager: permissions,
      appSettings: settings,
      keychainService: "com.justspeaktoit.tests.meta.routing.\(UUID().uuidString)"
    )
    let transcriber = SwitchingLiveTranscriber(
      appSettings: settings,
      permissionsManager: permissions,
      audioDeviceManager: audioDevices,
      secureStorage: secureStorage
    )

    XCTAssertTrue(
      transcriber.controller(for: MetaMuseVoiceTranscribe.liveCatalogID) is SharedClientLiveController
    )
  }

  @MainActor
  func testSettings_showRecognitionBiasOnlyForTheActiveMetaModel() {
    let settings = AppSettings()

    settings.transcriptionMode = .liveNative
    settings.liveTranscriptionModel = MetaMuseVoiceTranscribe.liveCatalogID
    XCTAssertTrue(settings.hasSelectedMetaMuseModel)

    settings.liveTranscriptionModel = "deepgram/nova-3-streaming"
    XCTAssertFalse(settings.hasSelectedMetaMuseModel)

    settings.transcriptionMode = .batchRemote
    settings.batchTranscriptionModel = MetaMuseVoiceTranscribe.batchCatalogID
    XCTAssertTrue(settings.hasSelectedMetaMuseModel)

    // The batch selection must not leak into the streaming card.
    settings.transcriptionMode = .liveNative
    XCTAssertFalse(settings.hasSelectedMetaMuseModel)
  }
}
