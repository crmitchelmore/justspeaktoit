import Foundation

public actor PersonalLexiconStore {
  private let fileURL: URL
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder
  private let fileManager: FileManager

  public init(fileManager: FileManager = .default, baseDirectory: URL? = nil, appDirectory: URL? = nil) {
    self.fileManager = fileManager
    let supportURL: URL
    if let baseDirectory {
      supportURL = baseDirectory
    } else {
      supportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }
    let appFolder = appDirectory
      ?? supportURL.appendingPathComponent(ReleaseTrain.current.supportDirectory, isDirectory: true)
    let lexiconFolder = appFolder.appendingPathComponent("PersonalLexicon", isDirectory: true)

    fileURL = lexiconFolder.appendingPathComponent("lexicon.json")

    encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
  }

  public func load() throws -> [PersonalLexiconRule] {
    guard fileManager.fileExists(atPath: fileURL.path) else {
      return []
    }

    let data = try Data(contentsOf: fileURL)
    return try decoder.decode([PersonalLexiconRule].self, from: data)
  }

  public func save(_ rules: [PersonalLexiconRule]) throws {
    if rules.isEmpty {
      if fileManager.fileExists(atPath: fileURL.path) {
        try fileManager.removeItem(at: fileURL)
      }
      return
    }

    let data = try encoder.encode(rules)
    try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: fileURL, options: [.atomic])
  }
}
