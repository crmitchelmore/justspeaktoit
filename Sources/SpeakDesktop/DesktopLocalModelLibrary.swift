import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakCore

/// Friendly names of imported models, registered by the host's library so
/// History and search show "ggml-medium.en from ggerganov/whisper.cpp" rather
/// than an identifier. Process-wide because History formatting is static.
public enum DesktopLocalModelNames {
    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var names: [String: String] = [:]
    }
    private static let storage = Storage()

    public static func register(_ models: [ImportedLocalModelFile]) {
        storage.lock.withLock {
            for model in models { storage.names[model.id.lowercased()] = model.displayName }
        }
    }

    public static func name(for identifier: String) -> String? {
        let key = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return storage.lock.withLock { storage.names[key] }
    }
}

/// The models a desktop host imported from Hugging Face, persisted beside the
/// downloads as `imported-hugging-face-models.json`. Each record is pinned to a
/// revision, byte count and SHA-256, so its download is verified like a
/// catalogue model's. Records that fail validation on load are dropped.
public final class DesktopLocalModelLibrary: @unchecked Sendable {
    public static let filename = "imported-hugging-face-models.json"

    public let url: URL
    private let lock = NSLock()
    private var records: [ImportedLocalModelFile]
    private let write: @Sendable (Data, URL) throws -> Void

    /// Loads the library in `directory`; a missing or unreadable file starts empty.
    public init(
        directory: URL,
        write: @escaping @Sendable (Data, URL) throws -> Void = { data, url in try data.write(to: url, options: .atomic) }
    ) {
        url = directory.appendingPathComponent(Self.filename)
        self.write = write
        let decoded = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([ImportedLocalModelFile].self, from: $0) }
        records = (decoded ?? []).filter(\.isValid)
        DesktopLocalModelNames.register(records)
    }

    public var imported: [ImportedLocalModelFile] { lock.withLock { records } }

    public func imported(kind: HuggingFaceModelFiles.Kind) -> [ImportedLocalModelFile] {
        imported.filter { $0.kind == kind }
    }

    /// Adds or re-pins a model and saves the library. Returns the stored record.
    @discardableResult
    public func add(_ candidate: HuggingFaceModelFiles.Candidate) throws -> ImportedLocalModelFile {
        let record = ImportedLocalModelFile(candidate: candidate)
        guard record.isValid else { throw HuggingFaceModelFiles.ListingError.unsupportedFile(candidate.path) }
        try lock.withLock {
            var updated = records.filter { $0.id != record.id }
            updated.append(record)
            try save(updated)
            records = updated
        }
        DesktopLocalModelNames.register([record])
        return record
    }

    /// Forgets an imported model. Its downloaded file is the host's to remove.
    public func remove(id: String) throws {
        try lock.withLock {
            let updated = records.filter { $0.id != id }
            guard updated.count != records.count else { return }
            try save(updated)
            records = updated
        }
    }

    public func transcriptionModels(host: LocalModelHostSupport) -> [WhisperCppModel] {
        DesktopLocalTranscription.models(host: host, imported: imported(kind: .whisperGGML))
    }

    /// Catalogue cleanup models, then GGUF imports.
    public func postProcessingModels(host: LocalModelHostSupport) -> [LlamaCppModel] {
        guard host.canExecute(.llamaCppGGUF) else { return [] }
        var seen = Set<String>()
        return (DesktopLocalPostProcessing.catalogueModels(host: host)
            + imported(kind: .llamaGGUF).compactMap(\.llamaCppModel)).filter { seen.insert($0.catalogueID).inserted }
    }

    public func postProcessingModel(for identifier: String, host: LocalModelHostSupport) -> LlamaCppModel? {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return postProcessingModels(host: host).first { $0.catalogueID == trimmed }
    }

    private func save(_ records: [ImportedLocalModelFile]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try write(encoder.encode(records), url)
    }
}

/// Reads Hugging Face repository listings for import.
public struct DesktopHuggingFaceClient: Sendable {
    public typealias Fetch = @Sendable (URL) async throws -> Data

    private let fetch: Fetch

    public init(fetch: @escaping Fetch) { self.fetch = fetch }

    /// Fetches over `session`, refusing non-2xx responses and oversized bodies.
    public init(session: URLSession = .shared) {
        self.init { url in
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw HuggingFaceModelFiles.ListingError.malformedResponse }
            switch http.statusCode {
            case 200..<300: break
            case 401, 403, 404: throw DesktopHuggingFaceError.repositoryUnavailable
            default: throw DesktopHuggingFaceError.status(http.statusCode)
            }
            guard data.count <= 16_000_000 else { throw HuggingFaceModelFiles.ListingError.malformedResponse }
            return data
        }
    }

    /// The importable GGML and GGUF files at the repository's current revision.
    public func listing(repository: String) async throws -> HuggingFaceModelFiles.Listing {
        guard let repoID = HuggingFaceModelFiles.normalizedRepoID(repository),
              let infoURL = HuggingFaceModelFiles.modelInfoURL(repoID: repoID) else {
            throw HuggingFaceModelFiles.ListingError.invalidRepository
        }
        let info = try HuggingFaceModelFiles.parseModelInfo(try await fetch(infoURL))
        guard let treeURL = HuggingFaceModelFiles.treeURL(repoID: repoID, revision: info.revision) else {
            throw HuggingFaceModelFiles.ListingError.malformedResponse
        }
        return try HuggingFaceModelFiles.parseTree(
            try await fetch(treeURL), repoID: repoID, revision: info.revision, license: info.license
        )
    }
}

public enum DesktopHuggingFaceError: LocalizedError, Equatable {
    case repositoryUnavailable
    case status(Int)

    public var errorDescription: String? {
        switch self {
        case .repositoryUnavailable:
            return "That Hugging Face repository does not exist or needs a sign-in. Only public repositories can be "
                + "imported."
        case .status(let code):
            return "Hugging Face answered with HTTP \(code). Try again later."
        }
    }
}
