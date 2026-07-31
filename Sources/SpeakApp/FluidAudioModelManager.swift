#if !APP_STORE
@preconcurrency import CoreML
import FluidAudio
import Foundation
import OSLog

enum FluidAudioParakeetModel {
  static let id = "local/streaming/fluidaudio/parakeet-realtime-eou-120m"
  static let displayName = "Parakeet Realtime EOU 120M"
  static let runtimeName = "FluidAudio / Core ML"
  static let approximateSizeMB = 430
  static let description = """
  Fast English-only local streaming with 160 ms chunks and end-of-utterance detection. \
  Audio stays on this Mac. The raw model output does not add punctuation or capitalisation.
  """

  static func matches(_ modelID: String) -> Bool {
    modelID == id
  }
}

enum FluidAudioModelError: LocalizedError {
  case notInstalled
  case unsupportedHardware
  case unsupportedLanguage(String)

  var errorDescription: String? {
    switch self {
    case .notInstalled:
      return "Download the Parakeet FluidAudio model in Settings before using Local Streaming."
    case .unsupportedHardware:
      return "Parakeet FluidAudio local streaming requires an Apple silicon Mac."
    case .unsupportedLanguage(let language):
      return "Parakeet Realtime EOU currently supports English only, not \(language)."
    }
  }
}

@MainActor
final class FluidAudioModelManager: ObservableObject {
  static let shared = FluidAudioModelManager()

  enum InstallState: Equatable {
    case notInstalled
    case installing
    case installed
    case failed(String)

    var isInstalled: Bool {
      if case .installed = self { return true }
      return false
    }
  }

  @Published private(set) var installState: InstallState = .notInstalled
  @Published private(set) var downloadProgress: Double = 0

  static var supportsCurrentHardware: Bool {
    #if arch(arm64)
    true
    #else
    false
    #endif
  }

  private let fileManager: FileManager
  private let modelsDirectory: URL
  private let logger = Logger(subsystem: "com.github.speakapp", category: "FluidAudioModel")

  init(
    fileManager: FileManager = .default,
    modelsDirectory: URL? = nil
  ) {
    self.fileManager = fileManager
    let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fileManager.homeDirectoryForCurrentUser
    self.modelsDirectory = modelsDirectory
      ?? applicationSupport
        .appendingPathComponent("SpeakApp", isDirectory: true)
        .appendingPathComponent("LocalModels", isDirectory: true)
        .appendingPathComponent("FluidAudio", isDirectory: true)
    refresh()
  }

  func refresh() {
    guard installState != .installing else { return }
    installState = requiredArtifactsExist ? .installed : .notInstalled
    downloadProgress = installState.isInstalled ? 1 : 0
  }

  func install() async {
    guard Self.supportsCurrentHardware else {
      installState = .failed(FluidAudioModelError.unsupportedHardware.localizedDescription)
      return
    }
    guard installState != .installing else { return }

    installState = .installing
    downloadProgress = 0
    do {
      try fileManager.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
      let manager = StreamingEouAsrManager(
        configuration: Self.modelConfiguration(),
        chunkSize: .ms160
      )
      try await manager.loadModels(
        to: modelsDirectory,
        configuration: Self.modelConfiguration(),
        progressHandler: { [weak self] progress in
          Task { @MainActor [weak self] in
            self?.downloadProgress = max(0, min(progress.fractionCompleted, 1))
          }
        }
      )
      await manager.cleanup()
      guard requiredArtifactsExist else {
        throw FluidAudioModelError.notInstalled
      }
      downloadProgress = 1
      installState = .installed
    } catch {
      logger.error("FluidAudio model installation failed: \(error.localizedDescription, privacy: .public)")
      installState = .failed(error.localizedDescription)
    }
  }

  func delete() {
    do {
      if fileManager.fileExists(atPath: modelDirectory.path) {
        try fileManager.removeItem(at: modelDirectory)
      }
      installState = .notInstalled
      downloadProgress = 0
    } catch {
      logger.error("FluidAudio model deletion failed: \(error.localizedDescription, privacy: .public)")
      installState = .failed(error.localizedDescription)
    }
  }

  func makeReadyManager() async throws -> StreamingEouAsrManager {
    guard Self.supportsCurrentHardware else {
      throw FluidAudioModelError.unsupportedHardware
    }
    refresh()
    guard installState.isInstalled else {
      throw FluidAudioModelError.notInstalled
    }

    let manager = StreamingEouAsrManager(
      configuration: Self.modelConfiguration(),
      chunkSize: .ms160
    )
    try await manager.loadModels(
      to: modelsDirectory,
      configuration: Self.modelConfiguration()
    )
    return manager
  }

  private var modelDirectory: URL {
    modelsDirectory.appendingPathComponent(Repo.parakeetEou160.folderName, isDirectory: true)
  }

  private var requiredArtifactsExist: Bool {
    ModelNames.ParakeetEOU.requiredModels.allSatisfy { artifact in
      fileManager.fileExists(atPath: modelDirectory.appendingPathComponent(artifact).path)
    }
  }

  private static func modelConfiguration() -> MLModelConfiguration {
    let configuration = MLModelConfiguration()
    configuration.computeUnits = .cpuAndNeuralEngine
    configuration.allowLowPrecisionAccumulationOnGPU = true
    return configuration
  }
}
#endif
