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

    XCTAssertEqual(presets.map(\.id), [.parakeetStreaming, .whisperKitStreaming, .whisperKitCompactStreaming])
    XCTAssertEqual(presets.first?.displayName, FluidAudioParakeetModel.displayName)
    XCTAssertEqual(whisperKitModel(in: presets)?.id, "local/whisperkit/large-v3-turbo")
  }

  func testRecommendedBatchPresets_preferPhononOnSupportedPlatform() {
    let presets = LocalTranscriptionStarterPreset.recommended(
      for: .batch,
      availableModels: ModelCatalog.localTranscription,
      supportsParakeet: true
    )

    XCTAssertEqual(presets.map(\.id), PhononLocalModels.isSupportedOnCurrentPlatform
      ? [.phononBatch, .whisperKitBatch, .whisperKitCompactBatch] : [.whisperKitBatch, .whisperKitCompactBatch])
    XCTAssertEqual(whisperKitModel(in: presets)?.id, "local/whisperkit/large-v3-turbo")
  }

  func testRecommendedStreamingPresets_omitParakeetOnUnsupportedHardware() {
    let presets = LocalTranscriptionStarterPreset.recommended(
      for: .streaming,
      availableModels: ModelCatalog.localTranscription,
      supportsParakeet: false
    )

    XCTAssertEqual(presets.map(\.id), [.whisperKitStreaming, .whisperKitCompactStreaming])
  }

  func testCompactPresets_useCanonicalModelMetadataAndOfferSmallerDownload() throws {
    for mode in [AppSettings.LocalTranscriptionMode.batch, .streaming] {
      let presets = LocalTranscriptionStarterPreset.recommended(
        for: mode, availableModels: ModelCatalog.localTranscription, supportsParakeet: false
      )
      let compact = try XCTUnwrap(presets.last)
      guard case .whisperKit(let model) = compact.engine else {
        return XCTFail("The compact preset must use WhisperKit")
      }
      XCTAssertEqual(model, ModelCatalog.localTranscription.first { $0.id == "local/whisperkit/base" })
      XCTAssertEqual(compact.approximateSizeMB, model.approximateSizeMB)
      XCTAssertLessThan(compact.approximateSizeMB, try XCTUnwrap(presets.first).approximateSizeMB)
      XCTAssertTrue(compact.detail.contains("Trades accuracy"))
    }
  }

  func testCompactPresets_omitUnavailableModelsAndNeverDuplicatePrimary() {
    let models = ModelCatalog.localTranscription.filter { $0.id == "local/whisperkit/base" }
    let presets = LocalTranscriptionStarterPreset.recommended(
      for: .batch, availableModels: models, supportsParakeet: false
    )
    XCTAssertEqual(presets.map(\.id), [.whisperKitBatch])
    XCTAssertTrue(LocalTranscriptionStarterPreset.recommended(
      for: .batch, availableModels: [], supportsParakeet: false
    ).isEmpty)
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
