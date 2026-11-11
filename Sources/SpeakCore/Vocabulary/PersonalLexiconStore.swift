import Foundation

public actor PersonalLexiconStore {
  private let fileURL: URL
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder
  private let fileManager: FileManager
  private var directory: VocabularyStoreDirectory

  public init(fileManager: FileManager = .default, baseDirectory: URL? = nil) {
    let supportURL: URL
    if let baseDirectory {
      supportURL = baseDirectory
    } else {
      supportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }
    self.init(
      fileManager: fileManager,
      appDirectory: supportURL.appendingPathComponent(ReleaseTrain.current.supportDirectory, isDirectory: true)
    )
  }

  public init(fileManager: FileManager = .default, appDirectory: URL) {
    self.fileManager = fileManager
    let lexiconFolder = appDirectory.appendingPathComponent("PersonalLexicon", isDirectory: true)
    directory = VocabularyStoreDirectory(fileManager: fileManager, url: lexiconFolder)
    fileURL = lexiconFolder.appendingPathComponent("lexicon.json")

    encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
  }

  public func load() throws -> [PersonalLexiconRule] {
    try directory.prepare()
    guard fileManager.fileExists(atPath: fileURL.path) else {
      return []
    }

    let data = try Data(contentsOf: fileURL)
    return try decoder.decode([PersonalLexiconRule].self, from: data)
  }

  public func save(_ rules: [PersonalLexiconRule]) throws {
    try directory.prepare()
    if rules.isEmpty {
      if fileManager.fileExists(atPath: fileURL.path) {
        try fileManager.removeItem(at: fileURL)
      }
      return
    }

    let data = try encoder.encode(rules)
    try data.write(to: fileURL, options: [.atomic])
  }
}
