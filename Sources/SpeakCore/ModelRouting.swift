import Foundation

public enum TranscriptionModelFamily: Equatable, Sendable {
    case appleSpeech
    case downloadedLocal(engine: String)
    case cloudStreaming(provider: String)
    case cloudBatch(provider: String)
    case postProcessing(provider: String)
    case unknown(provider: String?)

    public var isDownloadedLocal: Bool {
        if case .downloadedLocal = self { return true }
        return false
    }

    public var providerID: String? {
        switch self {
        case .appleSpeech:
            return "apple"
        case .downloadedLocal(let engine),
             .cloudStreaming(let engine),
             .cloudBatch(let engine),
             .postProcessing(let engine):
            return engine
        case .unknown(let provider):
            return provider
        }
    }
}

public enum ModelRouting {
    public static func family(for identifier: String) -> TranscriptionModelFamily {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unknown(provider: nil) }

        let components = trimmed.split(separator: "/").map(String.init)
        guard let provider = components.first?.lowercased() else { return .unknown(provider: nil) }

        if provider == "apple" {
            return .appleSpeech
        }
        if provider == "local" {
            return .downloadedLocal(engine: components.dropFirst().first?.lowercased() ?? "unknown")
        }
        if ModelCatalog.liveTranscription.contains(where: { $0.id == trimmed }) {
            return .cloudStreaming(provider: provider)
        }
        if ModelCatalog.batchTranscription.contains(where: { $0.id == trimmed }) {
            return .cloudBatch(provider: provider)
        }
        if ModelCatalog.postProcessing.contains(where: { $0.id == trimmed }) {
            return .postProcessing(provider: provider)
        }
        return .unknown(provider: provider)
    }

    public static func localModelName(from identifier: String) -> String? {
        let components = identifier.split(separator: "/").map(String.init)
        guard components.count >= 3, components[0].lowercased() == "local" else { return nil }
        return components.dropFirst(2).joined(separator: "/")
    }
}

public struct LocalTranscriptionModel: Identifiable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let modelName: String
    public let engine: String
    public let approximateSizeMB: Int
    public let description: String
    public let tags: [ModelCatalog.Tag]

    public init(
        id: String,
        displayName: String,
        modelName: String,
        engine: String,
        approximateSizeMB: Int,
        description: String,
        tags: [ModelCatalog.Tag]
    ) {
        self.id = id
        self.displayName = displayName
        self.modelName = modelName
        self.engine = engine
        self.approximateSizeMB = approximateSizeMB
        self.description = description
        self.tags = tags
    }

    public var option: ModelCatalog.Option {
        ModelCatalog.Option(
            id: id,
            displayName: displayName,
            description: description,
            estimatedLatencyMs: nil,
            latencyTier: tags.contains(.quality) ? .medium : .fast,
            tags: tags
        )
    }
}
