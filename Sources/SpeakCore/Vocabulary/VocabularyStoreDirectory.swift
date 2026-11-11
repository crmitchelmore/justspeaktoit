import Foundation

struct VocabularyStoreDirectory {
    private let fileManager: FileManager
    private let url: URL
    private var initialPreparation: Result<Void, Error>?

    init(fileManager: FileManager, url: URL) {
        self.fileManager = fileManager
        self.url = url
        initialPreparation = Result {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    mutating func prepare() throws {
        if let initialPreparation {
            // Keep the nonthrowing initializer API, but surface its failure on the first operation.
            self.initialPreparation = nil
            try initialPreparation.get()
        }
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
