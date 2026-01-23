import Foundation
import os.log

/// Persists auto-correction candidates to disk.
actor AutoCorrectionStore {
  private let fileURL: URL
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder
  private let fileManager: FileManager
  private let log = Logger(subsystem: "com.github.speakapp", category: "AutoCorrectionStore")

  init(fileManager: FileManager = .default, baseDirectory: URL? = nil) {
    self.fileManager = fileManager
    let supportURL: URL
    if let baseDirectory {
      supportURL = baseDirectory
    } else {
      supportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? fileManager.homeDirectoryForCurrentUser
    }
    let appFolder = supportURL.appendingPathComponent("SpeakApp", isDirectory: true)
    let autoCorrectionFolder = appFolder.appendingPathComponent("AutoCorrections", isDirectory: true)

    if !fileManager.fileExists(atPath: autoCorrectionFolder.path) {
      try? fileManager.createDirectory(at: autoCorrectionFolder, withIntermediateDirectories: true)
    }

    fileURL = autoCorrectionFolder.appendingPathComponent("candidates.json")

    encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
  }

  func load() throws -> [AutoCorrectionCandidate] {
    guard fileManager.fileExists(atPath: fileURL.path) else {
      return []
    }

    let data = try Data(contentsOf: fileURL)
    let candidates = try decoder.decode([AutoCorrectionCandidate].self, from: data)

    // Filter out expired candidates (older than 30 days with only 1 occurrence)
    let thirtyDaysAgo = Date().addingTimeInterval(-30 * 24 * 60 * 60)
    return candidates.filter { candidate in
      candidate.seenCount > 1 || candidate.lastSeenAt > thirtyDaysAgo
    }
  }

  func save(_ candidates: [AutoCorrectionCandidate]) throws {
    if candidates.isEmpty {
      if fileManager.fileExists(atPath: fileURL.path) {
        try fileManager.removeItem(at: fileURL)
      }
      return
    }

    let data = try encoder.encode(candidates)
    try data.write(to: fileURL, options: [.atomic])
  }

  func deleteAll() throws {
    if fileManager.fileExists(atPath: fileURL.path) {
      try fileManager.removeItem(at: fileURL)
    }
  }
}
