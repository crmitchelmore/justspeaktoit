import CryptoKit
import Foundation
import SpeakCore
import SpeakiOSLib
import UIKit
import WhisperKit

/// Runs downloaded WhisperKit Core ML models on iOS. WhisperKit is compiled
/// into the app; only model weights (data) are downloaded, never executable
/// code (App Store Review Guideline 2.5.2).
///
/// Each model gets its own directory under Application Support, keyed by a
/// hash of its `local/...` identifier, holding the Hub download and an
/// `installed.json` marker written only after the model has loaded once.
final class WhisperKitLocalTranscriptionEngine: IOSLocalTranscriptionEngine, @unchecked Sendable {
    private struct Marker: Codable {
        let version: Int
        let modelID: String
        let modelFolder: String
    }

    private let root: URL
    private let fileManager: FileManager
    private let pipelines = WhisperKitPipelineSlot()
    private var memoryWarningObserver: NSObjectProtocol?

    init(
        root: URL = IOSLocalModelsDirectory.root().appendingPathComponent("WhisperKit", isDirectory: true),
        fileManager: FileManager = .default
    ) {
        self.root = root
        self.fileManager = fileManager
        let pipelines = pipelines
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil
        ) { _ in
            Task { await pipelines.evict() }
        }
    }

    deinit {
        if let memoryWarningObserver { NotificationCenter.default.removeObserver(memoryWarningObserver) }
    }

    // MARK: - IOSLocalTranscriptionEngine

    func isInstalled(_ model: LocalTranscriptionModel) -> Bool {
        modelFolder(for: model) != nil
    }

    func installedSizeBytes(_ model: LocalTranscriptionModel) -> Int64? {
        guard isInstalled(model) else { return nil }
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = fileManager.enumerator(
            at: slot(for: model), includingPropertiesForKeys: keys, options: []
        ) else { return nil }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else {
                continue
            }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    func isRecommendedOnThisDevice(_ model: LocalTranscriptionModel) -> Bool {
        let repo = (model.modelRepo ?? WhisperKitHuggingFaceModels.argmaxRepoID).lowercased()
        guard repo == WhisperKitHuggingFaceModels.argmaxRepoID else { return true }
        let supported = WhisperKit.recommendedModels().supported.map { $0.lowercased() }
        guard !supported.isEmpty else { return true }
        let resolved = WhisperKitHuggingFaceModels.resolve(repoID: repo, modelName: model.modelName).modelName
        let candidates = Set([model.modelName, resolved].map { $0.lowercased() })
        return supported.contains { name in
            candidates.contains { name == $0 || name.hasSuffix("-\($0)") }
        }
    }

    func install(_ model: LocalTranscriptionModel, progress: @escaping @Sendable (Double) -> Void) async throws {
        let base = try prepareDownloadBase(for: model)
        let folder = try await WhisperKitIOSOffMain.download(
            variant: model.modelName,
            downloadBase: base,
            repo: model.modelRepo ?? WhisperKitHuggingFaceModels.argmaxRepoID,
            progress: { progress($0.fractionCompleted) }
        )
        try Task.checkCancellation()
        // Loading once fetches the tokenizer and compiles the Core ML models,
        // so the first recording doesn't pay for it, and proves the files work.
        let pipeline = try await WhisperKitIOSOffMain.load(configuration(for: model, folder: folder, base: base))
        await WhisperKitIOSOffMain.unload(pipeline)
        try Task.checkCancellation()
        try writeMarker(Marker(version: 1, modelID: model.id, modelFolder: relativePath(of: folder, in: base)), for: model)
    }

    func remove(_ model: LocalTranscriptionModel) throws {
        Task { await pipelines.evict(modelID: model.id) }
        let slot = slot(for: model)
        guard fileManager.fileExists(atPath: slot.path) else { return }
        // Marker first, so a partial removal never looks installed.
        try? fileManager.removeItem(at: markerURL(for: model))
        try fileManager.removeItem(at: slot)
    }

    func transcribe(fileAt url: URL, model: LocalTranscriptionModel, language: String?) async throws -> String {
        guard let folder = modelFolder(for: model) else {
            throw IOSLocalTranscriptionError.notDownloaded(model.displayName)
        }
        let config = configuration(for: model, folder: folder, base: downloadBase(for: model))
        let loaded = try await pipelines.pipeline(for: model.id) {
            LoadedWhisperKit(pipeline: try await WhisperKitIOSOffMain.load(config))
        }
        try Task.checkCancellation()
        let texts = try await WhisperKitIOSOffMain.transcribe(
            loaded.pipeline, audioPath: url.path, decodeOptions: Self.decodingOptions(language: language)
        )
        return texts.joined(separator: " ")
    }

    // MARK: - Decoding

    /// A BCP 47 tag such as `en-GB` becomes Whisper's `en`; no language lets
    /// Whisper detect it.
    static func decodingOptions(language: String?) -> DecodingOptions {
        let code = language?
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first
            .map { $0.lowercased() }
            .flatMap { $0.isEmpty ? nil : $0 }
        return DecodingOptions(task: .transcribe, language: code, usePrefillPrompt: code != nil, skipSpecialTokens: true)
    }

    // MARK: - Storage

    private func configuration(for model: LocalTranscriptionModel, folder: URL, base: URL) -> WhisperKitConfig {
        // modelFolder bypasses model downloading; downloadBase also holds the tokenizer.
        WhisperKitConfig(
            model: model.modelName,
            downloadBase: base,
            modelRepo: model.modelRepo,
            modelFolder: folder.path,
            tokenizerFolder: base,
            verbose: false,
            logLevel: .error,
            load: true,
            download: false
        )
    }

    private func slot(for model: LocalTranscriptionModel) -> URL {
        let key = SHA256.hash(data: Data(model.id.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(key, isDirectory: true)
    }

    private func downloadBase(for model: LocalTranscriptionModel) -> URL {
        slot(for: model).appendingPathComponent("hub", isDirectory: true)
    }

    private func markerURL(for model: LocalTranscriptionModel) -> URL {
        slot(for: model).appendingPathComponent("installed.json")
    }

    private func prepareDownloadBase(for model: LocalTranscriptionModel) throws -> URL {
        try IOSLocalModelsDirectory.prepare(root, fileManager: fileManager)
        let base = downloadBase(for: model)
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func modelFolder(for model: LocalTranscriptionModel) -> URL? {
        guard let data = try? Data(contentsOf: markerURL(for: model)),
              let marker = try? JSONDecoder().decode(Marker.self, from: data),
              marker.modelID == model.id else { return nil }
        let components = marker.modelFolder.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return nil
        }
        let folder = downloadBase(for: model).appendingPathComponent(marker.modelFolder, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return folder
    }

    private func relativePath(of folder: URL, in base: URL) throws -> String {
        let baseComponents = base.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let folderComponents = folder.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard folderComponents.count > baseComponents.count,
              Array(folderComponents.prefix(baseComponents.count)) == baseComponents else {
            throw IOSLocalTranscriptionError.notDownloaded(folder.lastPathComponent)
        }
        return folderComponents.dropFirst(baseComponents.count).joined(separator: "/")
    }

    private func writeMarker(_ marker: Marker, for model: LocalTranscriptionModel) throws {
        try JSONEncoder().encode(marker).write(to: markerURL(for: model), options: .atomic)
    }
}

/// A loaded pipeline. WhisperKit isn't `Sendable`; the slot below hands one
/// instance to one transcription at a time per recording, as macOS does.
private final class LoadedWhisperKit: @unchecked Sendable {
    let pipeline: WhisperKit

    init(pipeline: WhisperKit) {
        self.pipeline = pipeline
    }
}

/// Holds at most one loaded pipeline: Core ML weights are large, and a phone
/// should not keep two models in memory.
private actor WhisperKitPipelineSlot {
    private var active: (modelID: String, loaded: LoadedWhisperKit)?
    private var loading: (modelID: String, task: Task<LoadedWhisperKit, Error>)?

    func pipeline(
        for modelID: String, load: @escaping @Sendable () async throws -> LoadedWhisperKit
    ) async throws -> LoadedWhisperKit {
        if let active, active.modelID == modelID { return active.loaded }
        if let loading, loading.modelID == modelID { return try await loading.task.value }
        active = nil
        let task = Task { try await load() }
        loading = (modelID, task)
        defer { if self.loading?.modelID == modelID { self.loading = nil } }
        let loaded = try await task.value
        active = (modelID, loaded)
        return loaded
    }

    func evict(modelID: String? = nil) {
        guard modelID == nil || active?.modelID == modelID else { return }
        active = nil
    }
}

/// argmax-oss-swift builds with `NonisolatedNonsendingByDefault`, so its async
/// calls run on the caller's actor. These nonisolated helpers keep model
/// loading and decoding off the main actor (see `WhisperKitOffMain` on macOS).
enum WhisperKitIOSOffMain {
    nonisolated static func download(
        variant: String,
        downloadBase: URL,
        repo: String,
        progress: @escaping @Sendable (Progress) -> Void
    ) async throws -> URL {
        try await WhisperKit.download(
            variant: variant, downloadBase: downloadBase, from: repo, progressCallback: progress
        )
    }

    nonisolated static func load(_ config: WhisperKitConfig) async throws -> WhisperKit {
        try await WhisperKit(config)
    }

    nonisolated static func unload(_ pipeline: WhisperKit) async {
        await pipeline.unloadModels()
    }

    nonisolated static func transcribe(
        _ pipeline: WhisperKit,
        audioPath: String,
        decodeOptions: DecodingOptions
    ) async throws -> [String] {
        try await WhisperKitFileCancellation.run { request in
            try await pipeline.transcribe(
                audioPath: audioPath, decodeOptions: decodeOptions,
                callback: { _ in request.shouldContinue }
            ).map(\.text)
        }
    }
}
