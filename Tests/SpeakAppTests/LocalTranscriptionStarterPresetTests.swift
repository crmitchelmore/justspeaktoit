import SpeakCore
@testable import SpeakApp
import XCTest

final class LocalTranscriptionStarterPresetTests: XCTestCase {
  func testRecommendedStreamingPresets_includeParakeetAndLeadingWhisperKitModel() {
    let presets = LocalTranscriptionStarterPreset.recommended(
      for: .streaming,
      availableModels: ModelCatalog.localTranscription,
      supportsParakeet: true
    )

    XCTAssertEqual(presets.map(\.id), [.parakeetStreaming, .whisperKitStreaming])
    XCTAssertEqual(presets.first?.displayName, FluidAudioParakeetModel.displayName)
    XCTAssertEqual(whisperKitModel(in: presets)?.id, "local/whisperkit/large-v3-turbo")
  }

  func testRecommendedBatchPresets_onlyIncludeLeadingWhisperKitModel() {
    let presets = LocalTranscriptionStarterPreset.recommended(
      for: .batch,
      availableModels: ModelCatalog.localTranscription,
      supportsParakeet: true
    )

    XCTAssertEqual(presets.map(\.id), [.whisperKitBatch])
    XCTAssertEqual(whisperKitModel(in: presets)?.id, "local/whisperkit/large-v3-turbo")
  }

  func testRecommendedStreamingPresets_omitParakeetOnUnsupportedHardware() {
    let presets = LocalTranscriptionStarterPreset.recommended(
      for: .streaming,
      availableModels: ModelCatalog.localTranscription,
      supportsParakeet: false
    )

    XCTAssertEqual(presets.map(\.id), [.whisperKitStreaming])
  }

  func testPreferredWhisperKitModel_fallsBackToQualityAndFastModel() {
    let fallback = LocalTranscriptionModel(
      id: "local/whisperkit/future-model",
      displayName: "Future Model",
      modelName: "future-model",
      engine: .whisperKit,
      approximateSizeMB: 200,
      description: "A future quality model.",
      tags: [.quality, .fast],
      supportsLiveStreaming: true
    )

    XCTAssertEqual(
      LocalTranscriptionStarterPreset.preferredWhisperKitModel(
        from: [fallback],
        requiresStreaming: true
      ),
      fallback
    )
  }

  private func whisperKitModel(
    in presets: [LocalTranscriptionStarterPreset]
  ) -> LocalTranscriptionModel? {
    for preset in presets {
      if case .whisperKit(let model) = preset.engine {
        return model
      }
    }
    return nil
  }
}
