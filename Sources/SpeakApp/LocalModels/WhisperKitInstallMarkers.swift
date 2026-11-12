import Foundation
import SpeakCore

/// The `<model>.installed` markers that record a WhisperKit install, and the
/// install state those markers and the managed download storage imply.
struct WhisperKitInstallMarkers {
  /// Written by installs that downloaded into storage this app owns.
  static let managedMarker = "installed-managed-v1\n"

  let directory: URL
  let fileManager: FileManager
  let modelStorage: WhisperKitModelStorage

  func url(for model: LocalTranscriptionModel) -> URL {
    directory.appendingPathComponent(model.id.replacingOccurrences(of: "/", with: "_") + ".installed")
  }

  func exists(for model: LocalTranscriptionModel) -> Bool {
    fileManager.fileExists(atPath: url(for: model).path)
  }

  func recordManagedInstall(for model: LocalTranscriptionModel) throws {
    try Data(Self.managedMarker.utf8).write(to: url(for: model), options: .atomic)
  }

  func remove(for model: LocalTranscriptionModel) throws {
    let markerURL = url(for: model)
    if fileManager.fileExists(atPath: markerURL.path) {
      try fileManager.removeItem(at: markerURL)
    }
  }

  /// Legacy installs continue using their dependency-managed cache. Only an
  /// explicit installation selects a new owned base; deletion never guesses the
  /// old cache path. Reinstalling after removal migrates future downloads.
  func usesLegacyStorage(_ model: LocalTranscriptionModel) -> Bool {
    let marker = try? String(contentsOf: url(for: model), encoding: .utf8)
    return marker != nil && marker != Self.managedMarker
      && (try? modelStorage.hasOwnership(for: model.id)) == false
  }

  /// A managed install is only installed while its recorded model folder exists.
  func installState(for model: LocalTranscriptionModel) -> LocalModelManager.InstallState {
    guard exists(for: model) else { return .notInstalled }
    do {
      let marker = try String(contentsOf: url(for: model), encoding: .utf8)
      let hasOwnership = try modelStorage.hasOwnership(for: model.id)
      if marker == Self.managedMarker || hasOwnership {
        guard try modelStorage.modelFolder(for: model.id) != nil else {
          throw LocalModelError.missingManagedModelFolder
        }
      }
      return .installed
    } catch {
      return .failed(error.localizedDescription)
    }
  }
}
