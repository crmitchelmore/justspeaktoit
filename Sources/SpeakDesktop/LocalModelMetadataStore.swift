import Foundation
import SpeakCore

/// The existing private, atomic, bounded metadata-store discipline shared by
/// imported GGML and GGUF references. Decoding validates each model's fields.
struct LocalModelMetadataStore<Model: Codable & Identifiable & Sendable>: Sendable where Model.ID == String {
    let directory: URL
    let filename: String
    let prepareDirectory: @Sendable (URL) throws -> Void
    static var maximumBytes: Int { 128 * 1_024 }
    var url: URL { directory.appendingPathComponent(filename) }

    func load() throws -> [Model] {
        try prepareDirectory(directory)
        guard try FileManager.default.contentsOfDirectory(atPath: directory.path).contains(filename) else { return [] }
        try checkFile()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maximumBytes + 1) ?? Data()
        guard data.count <= Self.maximumBytes else { throw HuggingFaceWhisperError.invalidMetadata }
        let saved = try JSONDecoder().decode(Record.self, from: data)
        guard saved.version == 1 else { throw HuggingFaceWhisperError.invalidMetadata }
        try validate(saved.models)
        return saved.models
    }

    func save(_ models: [Model]) throws {
        try validate(models)
        let data = try JSONEncoder().encode(Record(version: 1, models: models))
        guard data.count <= Self.maximumBytes else { throw HuggingFaceWhisperError.invalidMetadata }
        try prepareDirectory(directory)
        if try FileManager.default.contentsOfDirectory(atPath: directory.path).contains(filename) { try checkFile() }
        try Task.checkCancellation()
        try data.write(to: url, options: .atomic)
    }

    private func checkFile() throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= Self.maximumBytes else {
            throw HuggingFaceWhisperError.invalidMetadata
        }
    }

    private func validate(_ models: [Model]) throws {
        guard models.count <= 64 else { throw HuggingFaceWhisperError.importLimit }
        guard Set(models.map(\.id)).count == models.count else { throw HuggingFaceWhisperError.invalidMetadata }
    }

    private struct Record: Codable { let version: Int; let models: [Model] }
}

public struct HuggingFaceGGUFStore: Sendable {
    public let directory: URL
    private let prepareDirectory: @Sendable (URL) throws -> Void
    public init(directory: URL, prepareDirectory: @escaping @Sendable (URL) throws -> Void) {
        self.directory = directory
        self.prepareDirectory = prepareDirectory
    }
    private var store: LocalModelMetadataStore<HuggingFaceGGUFModel> {
        .init(directory: directory, filename: "imported-llamacpp-gguf-models.json", prepareDirectory: prepareDirectory)
    }
    public var url: URL { store.url }
    public func load() throws -> [HuggingFaceGGUFModel] { try store.load() }
    public func save(_ models: [HuggingFaceGGUFModel]) throws { try store.save(models) }
}
