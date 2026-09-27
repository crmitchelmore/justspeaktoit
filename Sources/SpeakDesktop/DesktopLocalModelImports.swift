import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakCore

/// A model file the user imported from Hugging Face, pinned at import to the
/// revision, byte count and SHA-256 that Hugging Face reported for it, so
/// every download is verified like a catalogue model's.
///
/// Persisted in `imported-local-models.json`; keep the field names.
public struct DesktopImportedLocalModel: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// A GGML Whisper file for whisper.cpp (batch only; imports are never
        /// qualified for live use).
        case transcription
        /// A GGUF language model for llama.cpp post-processing.
        case postProcessing
    }

    public let kind: Kind
    public let identifier: String
    public let repoID: String
    /// The file's path inside the repository.
    public let path: String
    public let revision: String
    public let byteCount: Int64
    public let sha256: String
    /// The repository's declared licence, when it declares one.
    public let license: String?

    public init(
        kind: Kind, repoID: String, path: String, revision: String, byteCount: Int64, sha256: String, license: String?
    ) {
        self.kind = kind
        self.repoID = repoID
        self.path = path
        self.revision = revision
        self.byteCount = byteCount
        self.sha256 = sha256
        self.license = license
        let filename = String(path.split(separator: "/").last ?? Substring(path))
        switch kind {
        case .transcription:
            identifier = LocalModelIdentity.whisperCppHuggingFaceModelID(repoID: repoID, filename: filename)
        case .postProcessing:
            identifier = LocalModelIdentity.postProcessingHuggingFaceModelID(repoID: repoID, filename: filename)
        }
    }

    public var filename: String { String(path.split(separator: "/").last ?? Substring(path)) }

    /// "small.en q5 1 from ggerganov/whisper.cpp" or, for a language model,
    /// the Apple apps' "Qwen3 0.6B Q4 K M from unsloth/Qwen3-0.6B-GGUF".
    public var displayName: String {
        switch kind {
        case .transcription:
            var base = filename.replacingOccurrences(of: ".bin", with: "", options: [.caseInsensitive, .anchored, .backwards])
            if base.lowercased().hasPrefix("ggml-") { base.removeFirst(5) }
            base = base.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
            return "\(base) from \(repoID)"
        case .postProcessing:
            return LocalPostProcessingModel.importedDisplayName(repoID: repoID, filename: filename)
        }
    }

    public var artifact: LocalModelFileArtifact? {
        guard let url = LlamaCppModels.huggingFaceURL(repoID: repoID, revision: revision, filename: path) else {
            return nil
        }
        return LocalModelFileArtifact(
            url: url, filename: filename, byteCount: byteCount, sha256: sha256, license: license ?? "unspecified",
            provenance: "Imported from huggingface.co/\(repoID) at revision \(revision)"
        )
    }

    public var summary: String {
        "Imported from Hugging Face (\(repoID), revision \(revision.prefix(12))), "
            + "pinned by SHA-256 and verified after download."
    }

    public var whisperModel: WhisperCppModel? {
        guard kind == .transcription, let artifact else { return nil }
        return WhisperCppModel(
            catalogueID: identifier, displayName: displayName, summary: summary, quantization: "imported",
            multilingual: true, artifact: artifact, liveQualified: false
        )
    }

    public var languageModel: LlamaCppModel? {
        guard kind == .postProcessing, let artifact else { return nil }
        return LlamaCppModel(identifier: identifier, displayName: displayName, summary: summary, artifact: artifact)
    }
}

public enum DesktopLocalModelImportError: LocalizedError, Equatable {
    case invalidRepository
    case invalidFile(String)
    case notFound(String)
    case notLargeFileStorage(String)
    case tooLarge(String)
    case unreadableResponse

    public var errorDescription: String? {
        switch self {
        case .invalidRepository:
            return "Use the Hugging Face repository as owner/name, for example ggerganov/whisper.cpp."
        case .invalidFile(let detail): return detail
        case .notFound(let file): return "Hugging Face has no file \(file) in that repository."
        case .notLargeFileStorage(let file):
            return "\(file) is not stored with Git LFS, so Hugging Face publishes no SHA-256 to verify it against."
        case .tooLarge(let file): return "\(file) is larger than the 64 GB this app downloads."
        case .unreadableResponse: return "Hugging Face returned a response this app could not read."
        }
    }
}

/// Imported models and their persistence. Hosts load the store at launch,
/// then `register` it so History and pickers resolve imported names.
public struct DesktopLocalModelImports: Sendable, Equatable {
    public private(set) var models: [DesktopImportedLocalModel]

    public init(models: [DesktopImportedLocalModel] = []) {
        self.models = models
    }

    public static let fileName = "imported-local-models.json"

    /// Reads the store; a missing file is empty and unreadable entries are
    /// dropped rather than failing the launch.
    public static func load(from directory: URL) -> DesktopLocalModelImports {
        let url = directory.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([DesktopImportedLocalModel].self, from: data) else {
            return DesktopLocalModelImports()
        }
        return DesktopLocalModelImports(models: decoded.filter { $0.artifact != nil })
    }

    public func save(to directory: URL, write: (Data, URL) throws -> Void) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try write(encoder.encode(models), directory.appendingPathComponent(Self.fileName))
    }

    /// Adds or replaces the import with the same identifier.
    public mutating func add(_ model: DesktopImportedLocalModel) {
        models.removeAll { $0.identifier == model.identifier }
        models.append(model)
    }

    public mutating func remove(identifier: String) {
        models.removeAll { $0.identifier == identifier }
    }

    public func model(for identifier: String) -> DesktopImportedLocalModel? {
        let lowered = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return models.first { $0.identifier == lowered }
    }

    public func whisperModel(for identifier: String, host: LocalModelHostSupport) -> WhisperCppModel? {
        guard host.canExecute(.whisperCppGGML) else { return nil }
        return model(for: identifier)?.whisperModel
    }

    public func languageModel(for identifier: String, host: LocalModelHostSupport) -> LlamaCppModel? {
        guard host.canExecute(.llamaCppGGUF) else { return nil }
        return model(for: identifier)?.languageModel
    }

    public var whisperModels: [WhisperCppModel] { models.compactMap(\.whisperModel) }
    public var languageModels: [LlamaCppModel] { models.compactMap(\.languageModel) }

    // MARK: - Process-wide registration

    private final class Registry: @unchecked Sendable {
        let lock = NSLock()
        var imports = DesktopLocalModelImports()
    }
    private static let registry = Registry()

    /// The imports the host registered, for name resolution and lookups.
    public static var registered: DesktopLocalModelImports {
        registry.lock.withLock { registry.imports }
    }

    public static func register(_ imports: DesktopLocalModelImports) {
        registry.lock.withLock { registry.imports = imports }
    }

    /// The friendly name of an imported identifier: the registered import's
    /// name, otherwise one derived from the identifier so History never shows
    /// a generic label.
    public static func displayName(for identifier: String) -> String? {
        let lowered = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let model = registered.model(for: lowered) { return model.displayName }
        let prefix = LocalModelIdentity.whisperCppHuggingFacePrefix
        guard lowered.hasPrefix(prefix) else { return nil }
        let parts = lowered.dropFirst(prefix.count).split(separator: "/").map(String.init)
        guard parts.count >= 3 else { return nil }
        return "\(parts[2...].joined(separator: "/")) from \(parts[0])/\(parts[1])"
    }
}

/// Resolves a Hugging Face file to the revision, size and SHA-256 an import
/// pins, through the public model API (no account or token).
public enum HuggingFaceModelResolver {
    public typealias Fetch = @Sendable (URL) async throws -> Data

    /// Largest file accepted, far above any listed model.
    static let maximumBytes: Int64 = 64 << 30

    /// Checks the typed repository and file before any request. Language
    /// models must be `.gguf`; Whisper files must be whisper.cpp `.bin` GGML.
    public static func validate(
        repoID: String, path: String, kind: DesktopImportedLocalModel.Kind
    ) throws -> (repoID: String, path: String) {
        let repo = repoID.trimmingCharacters(in: .whitespacesAndNewlines)
        let file = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let segment = #"^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$"#
        let parts = repo.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, parts.allSatisfy({ $0.range(of: segment, options: .regularExpression) != nil }) else {
            throw DesktopLocalModelImportError.invalidRepository
        }
        let components = file.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !file.isEmpty, file.count <= 512,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") }) else {
            throw DesktopLocalModelImportError.invalidFile("Enter the file's path inside the repository.")
        }
        let lower = file.lowercased()
        switch kind {
        case .postProcessing:
            guard LocalPostProcessingModel.isGGUFFilename(lower) else {
                throw DesktopLocalModelImportError.invalidFile("A language model must be a .gguf file.")
            }
        case .transcription:
            guard lower.hasSuffix(".bin") else {
                throw DesktopLocalModelImportError.invalidFile(
                    "A Whisper model must be a whisper.cpp GGML .bin file, such as ggml-small.en.bin."
                )
            }
        }
        return (repo, file)
    }

    /// The kind a file name implies: `.gguf` is a language model, `.bin` a
    /// whisper.cpp Whisper file; nil for anything else.
    public static func kind(forPath path: String) -> DesktopImportedLocalModel.Kind? {
        let lower = path.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if LocalPostProcessingModel.isGGUFFilename(lower) { return .postProcessing }
        if lower.hasSuffix(".bin") { return .transcription }
        return nil
    }

    /// Pins the file at the repository's current main revision.
    public static func resolve(
        repoID: String, path: String, kind: DesktopImportedLocalModel.Kind, fetch: Fetch
    ) async throws -> DesktopImportedLocalModel {
        let (repo, file) = try validate(repoID: repoID, path: path, kind: kind)
        guard let infoURL = apiURL(repo: repo, suffix: "revision/main") else {
            throw DesktopLocalModelImportError.invalidRepository
        }
        let info = try decode(ModelInfo.self, from: await fetch(infoURL))
        guard info.sha.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil else {
            throw DesktopLocalModelImportError.unreadableResponse
        }
        let directory = file.split(separator: "/").dropLast().joined(separator: "/")
        guard let treeURL = apiURL(
            repo: repo, suffix: "tree/\(info.sha)" + (directory.isEmpty ? "" : "/\(directory)")
        ) else { throw DesktopLocalModelImportError.invalidFile("Enter the file's path inside the repository.") }
        let entries = try decode([TreeEntry].self, from: await fetch(treeURL))
        guard let entry = entries.first(where: { $0.type == "file" && $0.path == file }) else {
            throw DesktopLocalModelImportError.notFound(file)
        }
        guard let lfs = entry.lfs, lfs.oid.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw DesktopLocalModelImportError.notLargeFileStorage(file)
        }
        let size = lfs.size ?? entry.size ?? 0
        guard size > 0 else { throw DesktopLocalModelImportError.unreadableResponse }
        guard size <= maximumBytes else { throw DesktopLocalModelImportError.tooLarge(file) }
        return DesktopImportedLocalModel(
            kind: kind, repoID: repo, path: file, revision: info.sha, byteCount: size, sha256: lfs.oid,
            license: info.cardData?.license.flatMap { $0.isEmpty ? nil : String($0.prefix(64)) }
        )
    }

    /// A Hugging Face search for compatible files, opened in the browser.
    public static func browseURL(kind: DesktopImportedLocalModel.Kind) -> URL {
        switch kind {
        case .transcription:
            return URL(string: "https://huggingface.co/models?search=whisper%20ggml&sort=downloads")!
        case .postProcessing:
            return URL(string: "https://huggingface.co/models?library=gguf&pipeline_tag=text-generation&sort=downloads")!
        }
    }

    /// A URLSession fetch for hosts without their own HTTP stack; the
    /// response must be HTTP 200 JSON from huggingface.co.
    public static func urlSessionFetch(session: URLSession = .shared) -> Fetch {
        { url in
            var request = URLRequest(url: url)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 30
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw DesktopLocalModelImportError.unreadableResponse }
            if http.statusCode == 404 || http.statusCode == 401 {
                throw DesktopLocalModelImportError.notFound(url.lastPathComponent)
            }
            guard http.statusCode == 200 else { throw DesktopLocalModelImportError.unreadableResponse }
            return data
        }
    }

    private static func apiURL(repo: String, suffix: String) -> URL? {
        let allowed = CharacterSet.urlPathAllowed.subtracting(["?", "#"])
        guard let encoded = suffix.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "https://huggingface.co/api/models/\(repo)/\(encoded)")
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) } catch {
            throw DesktopLocalModelImportError.unreadableResponse
        }
    }

    private struct ModelInfo: Decodable {
        struct Card: Decodable {
            let license: String?
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: Keys.self)
                // A licence is usually a string but may be a list.
                license = (try? container.decode(String.self, forKey: .license))
                    ?? (try? container.decode([String].self, forKey: .license))?.first
            }
            enum Keys: String, CodingKey { case license }
        }
        let sha: String
        let cardData: Card?
    }

    private struct TreeEntry: Decodable {
        struct LFS: Decodable {
            let oid: String
            let size: Int64?
        }
        let type: String
        let path: String
        let size: Int64?
        let lfs: LFS?
    }
}
