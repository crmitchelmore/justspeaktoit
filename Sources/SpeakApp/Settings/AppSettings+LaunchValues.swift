import Foundation
import SpeakCore
import SpeakHotKeys

/// Values `AppSettings` reads once at launch whose loading is more than a
/// single stored-value lookup.
@MainActor
enum AppSettingsLaunchValues {
  /// Without timestamps, preserve competing nonempty edits. A deliberate clear
  /// after migration wins over a conflicting edit, which remains recoverable.
  /// Initial assignments do not invoke `didSet`, so the reconciliation is
  /// persisted here and the next launch cannot resurrect an old conflicting list.
  static func reconcileStoredTranscriptionKeywords(
    in defaults: UserDefaults
  ) -> (active: String, recovered: [String]) {
    let storedKeywords = SharedApplicationPreferences.transcriptionKeywords.macOS.value(in: defaults)
    let storedKeyterms = defaults.string(forKey: ApplicationPreferenceKey.assemblyAIKeyterms.rawValue) ?? ""
    let lastReconciled = defaults.string(forKey: ApplicationPreferenceKey.transcriptionKeywordsLastReconciled.rawValue)
    let reconciliation = TranscriptionKeywordPolicy.reconcile(
      canonical: storedKeywords, legacy: storedKeyterms, lastReconciled: lastReconciled
    )
    var recovered = defaults.stringArray(forKey: ApplicationPreferenceKey.recoveredTranscriptionKeywords.rawValue) ?? []
    if let conflict = reconciliation.recovered, !recovered.contains(conflict) {
      recovered.append(conflict)
      // Preserve the other edit before replacing either defaults mirror.
      defaults.set(recovered, forKey: ApplicationPreferenceKey.recoveredTranscriptionKeywords.rawValue)
    }
    let keywords = reconciliation.active
    if storedKeywords != keywords {
      defaults.set(keywords, forKey: ApplicationPreferenceKey.transcriptionKeywords.rawValue)
    }
    if storedKeyterms != keywords {
      defaults.set(keywords, forKey: ApplicationPreferenceKey.assemblyAIKeyterms.rawValue)
    }
    if lastReconciled != keywords {
      defaults.set(keywords, forKey: ApplicationPreferenceKey.transcriptionKeywordsLastReconciled.rawValue)
    }
    return (keywords, recovered)
  }

  static func storedRecordingsDirectory(in defaults: UserDefaults, fileManager: FileManager) -> URL {
    let defaultDirectory = defaultRecordingsDirectory(fileManager: fileManager)
    if let storedPath = defaults.string(forKey: ApplicationPreferenceKey.recordingsDirectory.rawValue),
      !storedPath.isEmpty {
      return URL(fileURLWithPath: storedPath, isDirectory: true)
    }
    return defaultDirectory
  }

  static func storedHotKey(in defaults: UserDefaults) -> HotKey {
    if let hotKeyData = defaults.data(forKey: ApplicationPreferenceKey.selectedHotKey.rawValue),
      let decoded = try? JSONDecoder().decode(HotKey.self, from: hotKeyData) {
      return decoded.isSupportedForGlobalMonitoring ? decoded : .fnKey
    }
    return .fnKey
  }

  private static func defaultRecordingsDirectory(fileManager: FileManager) -> URL {
    let base =
      fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fileManager.homeDirectoryForCurrentUser
    let appFolder = base.appendingPathComponent(ReleaseTrain.current.supportDirectory, isDirectory: true)
    let recordings = appFolder.appendingPathComponent("Recordings", isDirectory: true)
    if !fileManager.fileExists(atPath: recordings.path) {
      try? fileManager.createDirectory(at: recordings, withIntermediateDirectories: true)
    }
    return recordings
  }

  static func ensureDirectoryExists(_ directory: URL, fileManager: FileManager) {
    if !fileManager.fileExists(atPath: directory.path) {
      try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }
  }
}
