import Foundation

/// One vocabulary list persisted as an ISO-8601 JSON array in its own folder
/// under the app's support directory. An empty list removes the file.
///
/// Owned by an actor (`PersonalLexiconStore`, `AutoCorrectionStore`), which
/// serialises every call.
struct VocabularyJSONFile<Element: Codable> {
    private let fileManager: FileManager
    private let folderURL: URL
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var initialPreparation: Result<Void, Error>?

    /// The release train's support directory under `baseDirectory`, or under
    /// the user's Application Support folder when there is none.
    static func appDirectory(fileManager: FileManager, baseDirectory: URL?) -> URL {
        let supportURL = baseDirectory
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        return supportURL.appendingPathComponent(ReleaseTrain.current.supportDirectory, isDirectory: true)
    }

    init(fileManager: FileManager, appDirectory: URL, folder: String, fileName: String) {
        self.fileManager = fileManager
        self.folderURL = appDirectory.appendingPathComponent(folder, isDirectory: true)
        self.fileURL = self.folderURL.appendingPathComponent(fileName)
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
        let folderURL = self.folderURL
        self.initialPreparation = Result {
            try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
        }
    }

    mutating func load() throws -> [Element] {
        try self.prepare()
        guard self.fileManager.fileExists(atPath: self.fileURL.path) else { return [] }
        return try self.decoder.decode([Element].self, from: Data(contentsOf: self.fileURL))
    }

    mutating func save(_ elements: [Element]) throws {
        guard !elements.isEmpty else { return try self.deleteAll() }
        try self.prepare()
        try self.encoder.encode(elements).write(to: self.fileURL, options: [.atomic])
    }

    mutating func deleteAll() throws {
        try self.prepare()
        if self.fileManager.fileExists(atPath: self.fileURL.path) {
            try self.fileManager.removeItem(at: self.fileURL)
        }
    }

    private mutating func prepare() throws {
        if let initialPreparation {
            // Keep the stores' nonthrowing initialisers, but surface a failure on the first operation.
            self.initialPreparation = nil
            try initialPreparation.get()
        }
        try self.fileManager.createDirectory(at: self.folderURL, withIntermediateDirectories: true)
    }
}
