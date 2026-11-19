#if os(iOS)
import CryptoKit
import Foundation
import SpeakCore

/// The iOS projection of the pinned llama.cpp cleanup models
/// (`LlamaCppModels`, the same `local/post-processing/...` identifiers as the
/// desktop and Android), where their files live, and the integrity check that
/// runs before a file is loaded.
///
/// Capability rule: iOS applies the shared device-memory floor
/// (`LlamaCppAndroidExport.minimumDeviceMemoryBytes`) to
/// `ProcessInfo.physicalMemory`, so Qwen3 1.7B is offered only on devices with
/// enough memory to run it.
public enum IOSLocalCleanupModels {
    /// Cleanup budget for one transcript, load included.
    public static let timeout: TimeInterval = 120

    /// Every pinned model this build knows, whether or not this device runs it.
    public static var all: [LlamaCppModel] { LlamaCppModels.all }

    /// The pinned models offered on a device with `physicalMemory` bytes.
    public static func offered(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> [LlamaCppModel] {
        all.filter { isOffered($0, physicalMemory: physicalMemory) }
    }

    public static func isOffered(
        _ model: LlamaCppModel, physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> Bool {
        guard let floor = LlamaCppAndroidExport.minimumDeviceMemoryBytes(forCatalogueID: model.catalogueID) else {
            return true
        }
        return physicalMemory >= UInt64(floor)
    }

    public static func model(for identifier: String) -> LlamaCppModel? {
        LlamaCppModels.model(forCatalogueID: identifier)
    }

    /// Whether `identifier` names a downloaded cleanup model (not rules cleanup).
    public static func isCleanupModelID(_ identifier: String) -> Bool {
        model(for: identifier) != nil
    }

    public static func directory(root: URL = IOSLocalModelsDirectory.root()) -> URL {
        root.appendingPathComponent("Cleanup", isDirectory: true)
    }

    public static func fileURL(for model: LlamaCppModel, root: URL = IOSLocalModelsDirectory.root()) -> URL {
        directory(root: root).appendingPathComponent(model.artifact.filename, isDirectory: false)
    }

    /// Bytes on disk when the downloaded file has the pinned size, else `nil`.
    public static func installedSizeBytes(
        _ model: LlamaCppModel, root: URL = IOSLocalModelsDirectory.root()
    ) -> Int64? {
        let url = fileURL(for: model, root: root)
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber,
              size.int64Value == model.artifact.byteCount else { return nil }
        return size.int64Value
    }

    public static func isInstalled(_ model: LlamaCppModel, root: URL = IOSLocalModelsDirectory.root()) -> Bool {
        installedSizeBytes(model, root: root) != nil
    }

    // MARK: In use

    private final class InUse: @unchecked Sendable {
        let lock = NSLock()
        var identifiers: [String: Int] = [:]
    }

    private static let inUse = InUse()

    /// Whether a cleanup is running with `identifier`, so its file is kept.
    public static func isInUse(_ identifier: String) -> Bool {
        inUse.lock.lock()
        defer { inUse.lock.unlock() }
        return inUse.identifiers[identifier, default: 0] > 0
    }

    static func markInUse(_ identifier: String, _ active: Bool) {
        inUse.lock.lock()
        let count = inUse.identifiers[identifier, default: 0] + (active ? 1 : -1)
        inUse.identifiers[identifier] = count > 0 ? count : nil
        inUse.lock.unlock()
    }
}

/// Checks a downloaded file against its pinned size and SHA-256 before it is
/// loaded. The digest is computed once per file version (path, size and
/// modification date) in each process, so the first cleanup after a launch
/// re-reads the weights and later ones only re-check the size, as Android does.
public final class IOSPinnedWeightsVerifier: @unchecked Sendable {
    public static let shared = IOSPinnedWeightsVerifier()

    private struct Version: Hashable {
        let path: String
        let bytes: Int64
        let modified: Date
        let sha256: String
    }

    private let lock = NSLock()
    private var verified = Set<Version>()
    private let digest: (URL) throws -> String

    public init(digest: @escaping (URL) throws -> String = IOSPinnedWeightsVerifier.sha256) {
        self.digest = digest
    }

    public func verify(_ artifact: LocalModelFileArtifact, file: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              (attributes[.type] as? FileAttributeType) == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.int64Value == artifact.byteCount else { return false }
        let version = Version(
            path: file.standardizedFileURL.path, bytes: size.int64Value,
            modified: attributes[.modificationDate] as? Date ?? .distantPast, sha256: artifact.sha256
        )
        lock.lock()
        let known = verified.contains(version)
        lock.unlock()
        if known { return true }
        guard let actual = try? digest(file), actual == artifact.sha256 else { return false }
        lock.lock()
        verified.insert(version)
        lock.unlock()
        return true
    }

    /// Lowercase hexadecimal SHA-256 of a file, read in 4 MiB chunks.
    public static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try autoreleasepool { try handle.read(upToCount: 4 * 1_024 * 1_024) }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Cleans a transcript with a downloaded model. The SYSTEM message is the
/// cleanup prompt plus the local-engine constraint; the USER message is the
/// transcript wrapped as data. Any failure throws `IOSLocalCleanupError`, so
/// the caller keeps the original transcript and shows why.
public struct IOSLocalCleanup: Sendable {
    let engine: @Sendable () -> IOSLocalCleanupEngine?
    let verifier: IOSPinnedWeightsVerifier
    let physicalMemory: UInt64
    let root: URL
    let timeout: TimeInterval

    public init(
        engine: @escaping @Sendable () -> IOSLocalCleanupEngine? = { IOSLocalCleanupEngines.current },
        verifier: IOSPinnedWeightsVerifier = .shared,
        physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory,
        root: URL = IOSLocalModelsDirectory.root(),
        timeout: TimeInterval = IOSLocalCleanupModels.timeout
    ) {
        self.engine = engine
        self.verifier = verifier
        self.physicalMemory = physicalMemory
        self.root = root
        self.timeout = timeout
    }

    /// Cleans `transcript` with the stock cleanup policy.
    public func clean(_ transcript: String, modelID: String) async throws -> String {
        try await respond(
            transcript: transcript,
            systemPrompt: TranscriptCleanupPolicy.systemPrompt(),
            userMessage: LocalCleanupPrompt.userMessage(transcript: transcript),
            modelID: modelID
        )
    }

    /// Runs a prompt pair: the cleanup policy or the Polish Text intent's
    /// custom prompt, with only the local-engine constraint appended to it.
    /// A transcript with nothing to clean is returned as it is, without
    /// loading the model.
    public func respond(
        transcript: String, systemPrompt: String, userMessage: String, modelID: String
    ) async throws -> String {
        if LocalCleanupPrompt.isEmpty(transcript) { return transcript }
        guard let model = IOSLocalCleanupModels.model(for: modelID) else {
            throw IOSLocalCleanupError.unknownModel(modelID)
        }
        let name = model.displayName
        guard IOSLocalCleanupModels.isOffered(model, physicalMemory: physicalMemory) else {
            throw IOSLocalCleanupError.notOfferedOnThisDevice(name)
        }
        guard let engine = engine() else { throw IOSLocalCleanupError.engineUnavailable }
        let file = IOSLocalCleanupModels.fileURL(for: model, root: root)
        guard FileManager.default.fileExists(atPath: file.path) else { throw IOSLocalCleanupError.notDownloaded(name) }

        IOSLocalCleanupModels.markInUse(model.catalogueID, true)
        defer { IOSLocalCleanupModels.markInUse(model.catalogueID, false) }
        let verifier = self.verifier
        let artifact = model.artifact
        let verified = await Task.detached(priority: .userInitiated) { verifier.verify(artifact, file: file) }.value
        guard verified else { throw IOSLocalCleanupError.verificationFailed(name) }
        try Task.checkCancellation()

        let reply = try await engine.complete(
            modelFile: file,
            systemPrompt: LocalCleanupPrompt.explicitSystemPrompt(systemPrompt),
            userMessage: userMessage,
            timeout: timeout
        )
        if LocalCleanupPrompt.containsThinking(reply) { throw IOSLocalCleanupError.thinkingAloud(name) }
        let cleaned = LocalCleanupPrompt.unwrappedReply(reply)
        guard !cleaned.isEmpty else { throw IOSLocalCleanupError.noUsableAnswer(name) }
        return cleaned
    }
}
#endif
