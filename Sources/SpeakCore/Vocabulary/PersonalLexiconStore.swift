import Foundation

public actor PersonalLexiconStore {
  private var file: VocabularyJSONFile<PersonalLexiconRule>

  public init(fileManager: FileManager = .default, baseDirectory: URL? = nil) {
    self.init(
      fileManager: fileManager,
      appDirectory: VocabularyJSONFile<PersonalLexiconRule>.appDirectory(
        fileManager: fileManager, baseDirectory: baseDirectory
      )
    )
  }

  public init(fileManager: FileManager = .default, appDirectory: URL) {
    file = VocabularyJSONFile(
      fileManager: fileManager, appDirectory: appDirectory, folder: "PersonalLexicon", fileName: "lexicon.json"
    )
  }

  public func load() throws -> [PersonalLexiconRule] {
    try file.load()
  }

  public func save(_ rules: [PersonalLexiconRule]) throws {
    try file.save(rules)
  }
}
