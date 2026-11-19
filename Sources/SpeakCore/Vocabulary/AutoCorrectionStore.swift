import Foundation

/// Persists auto-correction candidates to disk.
public actor AutoCorrectionStore {
  /// Candidates older than this with only 1 occurrence are auto-expired
  private static let candidateExpirationInterval: TimeInterval = 30 * 24 * 60 * 60  // 30 days

  private var file: VocabularyJSONFile<AutoCorrectionCandidate>

  public init(fileManager: FileManager = .default, baseDirectory: URL? = nil) {
    self.init(
      fileManager: fileManager,
      appDirectory: VocabularyJSONFile<AutoCorrectionCandidate>.appDirectory(
        fileManager: fileManager, baseDirectory: baseDirectory
      )
    )
  }

  public init(fileManager: FileManager = .default, appDirectory: URL) {
    file = VocabularyJSONFile(
      fileManager: fileManager, appDirectory: appDirectory, folder: "AutoCorrections", fileName: "candidates.json"
    )
  }

  public func load() throws -> [AutoCorrectionCandidate] {
    // Filter out expired candidates (older than 30 days with only 1 occurrence)
    let expirationDate = Date().addingTimeInterval(-Self.candidateExpirationInterval)
    return try file.load().filter { candidate in
      candidate.seenCount > 1 || candidate.lastSeenAt > expirationDate
    }
  }

  public func save(_ candidates: [AutoCorrectionCandidate]) throws {
    try file.save(candidates)
  }

  public func deleteAll() throws {
    try file.deleteAll()
  }
}
