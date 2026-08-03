import SpeakCore

struct LocalTranscriptionStarterPreset: Identifiable, Equatable {
  enum PresetID: String, Hashable {
    case parakeetStreaming
    case whisperKitStreaming
    case whisperKitBatch
  }

  enum Engine: Equatable {
    case parakeet
    case whisperKit(LocalTranscriptionModel)
  }

  let id: PresetID
  let mode: AppSettings.LocalTranscriptionMode
  let engine: Engine
  let recommendation: String
  let detail: String
  let runtime: String
  let approximateSizeMB: Int

  var displayName: String {
    switch engine {
    case .parakeet:
      return FluidAudioParakeetModel.displayName
    case .whisperKit(let model):
      return model.displayName
    }
  }

  static func recommended(
    for mode: AppSettings.LocalTranscriptionMode,
    availableModels: [LocalTranscriptionModel],
    supportsParakeet: Bool
  ) -> [Self] {
    let whisperKitModel = preferredWhisperKitModel(
      from: availableModels,
      requiresStreaming: mode == .streaming
    )

    switch mode {
    case .streaming:
      var presets: [Self] = []
      if supportsParakeet {
        presets.append(
          Self(
            id: .parakeetStreaming,
            mode: .streaming,
            engine: .parakeet,
            recommendation: "Fastest for English",
            detail: FluidAudioParakeetModel.description,
            runtime: FluidAudioParakeetModel.runtimeName,
            approximateSizeMB: FluidAudioParakeetModel.approximateSizeMB
          )
        )
      }
      if let whisperKitModel {
        presets.append(
          Self(
            id: .whisperKitStreaming,
            mode: .streaming,
            engine: .whisperKit(whisperKitModel),
            recommendation: "Best for multilingual dictation",
            detail: whisperKitModel.description,
            runtime: "WhisperKit / Core ML",
            approximateSizeMB: whisperKitModel.approximateSizeMB
          )
        )
      }
      return presets
    case .batch:
      guard let whisperKitModel else { return [] }
      return [
        Self(
          id: .whisperKitBatch,
          mode: .batch,
          engine: .whisperKit(whisperKitModel),
          recommendation: "Best quality for finished recordings",
          detail: whisperKitModel.description,
          runtime: "WhisperKit / Core ML",
          approximateSizeMB: whisperKitModel.approximateSizeMB
        )
      ]
    }
  }

  static func preferredWhisperKitModel(
    from availableModels: [LocalTranscriptionModel],
    requiresStreaming: Bool
  ) -> LocalTranscriptionModel? {
    let candidates = availableModels.filter { model in
      model.engine == .whisperKit && (!requiresStreaming || model.supportsLiveStreaming)
    }
    return candidates.first { $0.tags.contains(.leading) }
      ?? candidates.first { $0.tags.contains(.quality) && $0.tags.contains(.fast) }
      ?? candidates.first { $0.tags.contains(.quality) }
      ?? candidates.first
  }
}
