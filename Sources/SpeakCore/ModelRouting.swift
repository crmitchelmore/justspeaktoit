import Foundation

public enum LocalTranscriptionEngine: Hashable, Sendable {
    case whisperKit
    case transcribeCpp
    case streaming
    case unknown(String)

    public init(identifier: String) {
        switch identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "whisperkit": self = .whisperKit
        case "transcribe.cpp", "transcribe-cpp": self = .transcribeCpp
        case "streaming": self = .streaming
        case let identifier: self = .unknown(identifier)
        }
    }

    public var identifier: String {
        switch self {
        case .whisperKit: return "whisperkit"
        case .transcribeCpp: return "transcribe.cpp"
        case .streaming: return "streaming"
        case .unknown(let identifier): return identifier
        }
    }

    public var displayName: String {
        switch self {
        case .whisperKit: return "WhisperKit"
        case .transcribeCpp: return "transcribe.cpp"
        case .streaming: return "Streaming"
        case .unknown(let identifier): return identifier.capitalized
        }
    }
}

extension LocalTranscriptionEngine: Codable {
    public init(from decoder: Decoder) throws {
        self.init(identifier: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(identifier)
    }
}

public enum TranscriptionModelFamily: Equatable, Sendable {
    case appleSpeech
    case downloadedLocal(engine: LocalTranscriptionEngine)
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
        case .downloadedLocal(let engine):
            return engine.identifier
        case .cloudStreaming(let engine),
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
        if ModelCatalog.postProcessing.contains(where: { $0.id == trimmed })
            || trimmed.lowercased().hasPrefix("local/post-processing/") {
            return .postProcessing(provider: provider)
        }
        if provider == "local" {
            return .downloadedLocal(
                engine: LocalTranscriptionEngine(
                    identifier: components.dropFirst().first ?? "unknown"
                )
            )
        }
        if ModelCatalog.liveTranscription.contains(where: { $0.id == trimmed }) {
            return .cloudStreaming(provider: provider)
        }
        if ModelCatalog.batchTranscription.contains(where: { $0.id == trimmed }) {
            return .cloudBatch(provider: provider)
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
    public let engine: LocalTranscriptionEngine
    public let modelRepo: String?
    public let approximateSizeMB: Int
    public let description: String
    public let tags: [ModelCatalog.Tag]
    public let supportsLiveStreaming: Bool

    public init(
        id: String,
        displayName: String,
        modelName: String,
        engine: LocalTranscriptionEngine,
        modelRepo: String? = nil,
        approximateSizeMB: Int,
        description: String,
        tags: [ModelCatalog.Tag],
        supportsLiveStreaming: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.modelName = modelName
        self.engine = engine
        self.modelRepo = modelRepo
        self.approximateSizeMB = approximateSizeMB
        self.description = description
        self.tags = tags
        self.supportsLiveStreaming = supportsLiveStreaming
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
