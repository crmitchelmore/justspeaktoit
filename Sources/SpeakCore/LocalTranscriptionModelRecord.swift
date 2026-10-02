import Foundation

/// The persisted form of an imported `LocalTranscriptionModel`, as stored in
/// `imported-hugging-face-models.json` and data-migration archives.
///
/// Field names and types are a storage format, including the optional
/// `modelRepo` (omitted when absent). An unknown engine survives a load and
/// save, normalised to trimmed lowercase by `LocalTranscriptionEngine`. Tags are
/// not persisted: every imported model loads with `[.quality]`.
public struct LocalTranscriptionModelRecord: Codable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let modelName: String
    public let engine: String
    public let modelRepo: String?
    public let approximateSizeMB: Int
    public let description: String
    public let supportsLiveStreaming: Bool

    public init(model: LocalTranscriptionModel) {
        id = model.id
        displayName = model.displayName
        modelName = model.modelName
        engine = model.engine.identifier
        modelRepo = model.modelRepo
        approximateSizeMB = model.approximateSizeMB
        description = model.description
        supportsLiveStreaming = model.supportsLiveStreaming
    }

    public var model: LocalTranscriptionModel {
        LocalTranscriptionModel(
            id: id,
            displayName: displayName,
            modelName: modelName,
            engine: LocalTranscriptionEngine(identifier: engine),
            modelRepo: modelRepo,
            approximateSizeMB: approximateSizeMB,
            description: description,
            tags: [.quality],
            supportsLiveStreaming: supportsLiveStreaming
        )
    }
}
