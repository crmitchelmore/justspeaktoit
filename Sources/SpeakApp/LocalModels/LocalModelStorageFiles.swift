import Foundation
import SpeakCore

/// The folder every downloaded local-model runtime keeps its files under:
/// `Application Support/<release train>/LocalModels`.
enum LocalModelsDirectory {
  static func root(fileManager: FileManager = .default) -> URL {
    let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fileManager.homeDirectoryForCurrentUser
    return base
      .appendingPathComponent(ReleaseTrain.current.supportDirectory, isDirectory: true)
      .appendingPathComponent("LocalModels", isDirectory: true)
  }
}

/// A user-added model or source list persisted as one JSON array, such as the
/// imported WhisperKit models or the imported GGUF post-processing models.
struct LocalModelSourceFile<Record: Codable> {
  let url: URL
  let fileManager: FileManager

  init(url: URL, fileManager: FileManager = .default) {
    self.url = url
    self.fileManager = fileManager
  }

  /// The stored records, or `nil` when nothing has been saved yet.
  func load() throws -> [Record]? {
    guard fileManager.fileExists(atPath: url.path) else { return nil }
    return try JSONDecoder().decode([Record].self, from: Data(contentsOf: url))
  }

  func save(_ records: [Record]) throws {
    try JSONEncoder().encode(records).write(to: url, options: .atomic)
  }
}

/// Validation shared by every "add a Hugging Face model" form.
enum HuggingFaceRepoInput {
  /// Whether the text names an `owner/repo` repository. Callers trim first
  /// when they submit, so a form can enable before trailing spaces are gone.
  static func isValidRepoID(_ text: String) -> Bool {
    text.split(separator: "/").count == 2
  }
}

/// Installs a download through a `.download` sibling that replaces the final
/// file or folder only once `fill` succeeds, so a failed or cancelled
/// download never leaves partial files where a model is expected.
@MainActor
enum StagedModelInstall {
  static func install(
    at finalURL: URL,
    fileManager: FileManager = .default,
    fill: (_ stagingURL: URL) async throws -> Void
  ) async throws {
    let stagingURL = finalURL.deletingLastPathComponent()
      .appendingPathComponent(finalURL.lastPathComponent + ".download", isDirectory: finalURL.hasDirectoryPath)
    defer {
      if fileManager.fileExists(atPath: stagingURL.path) {
        try? fileManager.removeItem(at: stagingURL)
      }
    }
    if fileManager.fileExists(atPath: stagingURL.path) {
      try fileManager.removeItem(at: stagingURL)
    }
    try fileManager.createDirectory(at: finalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try await fill(stagingURL)
    if fileManager.fileExists(atPath: finalURL.path) {
      try fileManager.removeItem(at: finalURL)
    }
    try fileManager.moveItem(at: stagingURL, to: finalURL)
  }
}
