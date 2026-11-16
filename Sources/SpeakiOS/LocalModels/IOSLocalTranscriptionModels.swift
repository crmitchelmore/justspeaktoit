#if os(iOS)
import Foundation
import SpeakCore

/// The user's Hugging Face WhisperKit imports, persisted as
/// `imported-hugging-face-models.json` in the same record format as macOS.
public final class IOSImportedLocalModelStore: @unchecked Sendable {
    public static let shared = IOSImportedLocalModelStore(directory: IOSLocalModelsDirectory.root())

    private let fileURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private var cached: [LocalTranscriptionModel]?

    public init(directory: URL, fileManager: FileManager = .default) {
        fileURL = directory.appendingPathComponent("imported-hugging-face-models.json")
        self.fileManager = fileManager
    }

    /// Imports with legacy identifiers normalised; a migrated list is written back.
    public func load() -> [LocalTranscriptionModel] {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        guard let data = try? Data(contentsOf: fileURL),
              let records = try? JSONDecoder().decode([LocalTranscriptionModelRecord].self, from: data) else {
            cached = []
            return []
        }
        let (models, didMigrate) = WhisperKitHuggingFaceModels.loadImportedModels(from: records)
        let runnable = LocalModelHostSupport.iOS.executableModels(in: models)
        cached = runnable
        if didMigrate { try? write(runnable) }
        return runnable
    }

    public func save(_ models: [LocalTranscriptionModel]) throws {
        lock.lock()
        defer { lock.unlock() }
        try write(models)
        cached = models
    }

    private func write(_ models: [LocalTranscriptionModel]) throws {
        try IOSLocalModelsDirectory.prepare(fileURL.deletingLastPathComponent(), fileManager: fileManager)
        let data = try JSONEncoder().encode(models.map(LocalTranscriptionModelRecord.init(model:)))
        try data.write(to: fileURL, options: .atomic)
    }
}

/// Resolves and checks downloaded `local/...` transcription models on iOS.
///
/// The catalogue is `ModelCatalog.iOSLocalTranscription` plus the user's
/// imports; nothing here lists models of its own.
public enum IOSLocalTranscriptionModels {
    /// Whether `identifier` names a downloaded model rather than Apple Speech
    /// (`apple/local/...`) or a cloud model.
    public static func isDownloadedModelID(_ identifier: String) -> Bool {
        identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("local/")
    }

    public static func all(
        imported: [LocalTranscriptionModel] = IOSImportedLocalModelStore.shared.load()
    ) -> [LocalTranscriptionModel] {
        WhisperKitHuggingFaceModels.deduplicated(ModelCatalog.iOSLocalTranscription + imported)
    }

    public static func model(
        for identifier: String,
        imported: [LocalTranscriptionModel] = IOSImportedLocalModelStore.shared.load()
    ) -> LocalTranscriptionModel? {
        guard isDownloadedModelID(identifier) else { return nil }
        let normalized = WhisperKitHuggingFaceModels.normalizedModelID(identifier)
        return all(imported: imported).first { $0.id.caseInsensitiveCompare(normalized) == .orderedSame }
    }

    /// The model and engine that will run `identifier`, or the reason it can't.
    public static func requireReady(
        _ identifier: String,
        engine: IOSLocalTranscriptionEngine? = IOSLocalTranscriptionEngines.current,
        imported: [LocalTranscriptionModel] = IOSImportedLocalModelStore.shared.load()
    ) throws -> (model: LocalTranscriptionModel, engine: IOSLocalTranscriptionEngine) {
        guard let model = model(for: identifier, imported: imported) else {
            throw IOSLocalTranscriptionError.unknownModel(identifier)
        }
        guard let engine else { throw IOSLocalTranscriptionError.engineUnavailable }
        guard engine.isInstalled(model) else { throw IOSLocalTranscriptionError.notDownloaded(model.displayName) }
        return (model, engine)
    }

    public static func isReady(
        _ identifier: String,
        engine: IOSLocalTranscriptionEngine? = IOSLocalTranscriptionEngines.current
    ) -> Bool {
        (try? requireReady(identifier, engine: engine)) != nil
    }

    // MARK: - In-use tracking, so a model can't be removed mid-transcription.

    private final class UseCounts: @unchecked Sendable {
        let lock = NSLock()
        var counts: [String: Int] = [:]
    }

    private static let uses = UseCounts()

    static func beginUse(_ modelID: String) {
        uses.lock.lock()
        uses.counts[modelID, default: 0] += 1
        uses.lock.unlock()
    }

    static func endUse(_ modelID: String) {
        uses.lock.lock()
        let remaining = uses.counts[modelID, default: 1] - 1
        uses.counts[modelID] = remaining > 0 ? remaining : nil
        uses.lock.unlock()
    }

    public static func isInUse(_ modelID: String) -> Bool {
        uses.lock.lock()
        defer { uses.lock.unlock() }
        return uses.counts[modelID] != nil
    }

    // MARK: - Transcription

    /// Transcribes a completed recording with a downloaded model. Refuses
    /// rather than uploading when the model or engine is missing; a silent
    /// recording throws `emptyTranscript`, never placeholder text.
    static func transcribe(
        at url: URL,
        modelID: String,
        language: String?,
        engine: IOSLocalTranscriptionEngine? = IOSLocalTranscriptionEngines.current,
        imported: [LocalTranscriptionModel] = IOSImportedLocalModelStore.shared.load()
    ) async throws -> TranscriptionResult {
        let (model, engine) = try requireReady(modelID, engine: engine, imported: imported)
        beginUse(model.id)
        defer { endUse(model.id) }
        let raw = try await engine.transcribe(fileAt: url, model: model, language: language)
        let text = TranscriptPostProcessingPolicy.cleanedWhisperTranscript(raw)
        guard !text.isEmpty else { throw IOSBatchTranscriptionError.emptyTranscript }
        return TranscriptionResult(
            text: text,
            segments: [],
            confidence: nil,
            duration: await resolvedTranscriptionDuration(reported: nil, lastSegmentEnd: nil, audioURL: url),
            modelIdentifier: model.id,
            cost: nil,
            rawPayload: nil,
            debugInfo: nil
        )
    }
}
#endif
