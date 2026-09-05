import Foundation

/// Dedicated audio endpoints; chat models with an `audio` modality are deliberately excluded.
public enum OpenRouterAudioCapability: String, Codable, CaseIterable, Sendable {
    case transcription
    case speech
}

/// Metadata supplied by OpenRouter, shared by both platforms without a built-in model or voice list.
public struct OpenRouterAudioModel: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let description: String
    public let inputModalities: [String]
    public let outputModalities: [String]
    /// Preserve the provider's keys and decimal strings. Do not infer a per-token price from `prompt`.
    public let pricing: [String: String]
    public let supportedParameters: [String]
    public let supportedVoices: [String]
    public let contextLength: Int?
    public let expirationDate: String?

    public var capability: OpenRouterAudioCapability? {
        OpenRouterAudioCapability.allCases.first { supports($0) }
    }

    public var transcriptionSelectionID: String { OpenRouterTranscriptionSelection.identifier(for: id) }

    public func supports(_ capability: OpenRouterAudioCapability) -> Bool {
        outputModalities.contains(capability.rawValue)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, description, architecture, pricing
        case supportedParameters = "supported_parameters"
        case supportedVoices = "supported_voices"
        case contextLength = "context_length"
        case expirationDate = "expiration_date"
    }

    private struct PriceValue: Decodable {
        let value: String?

        init(from decoder: Decoder) throws {
            value = try? decoder.singleValueContainer().decode(String.self)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        let selectionID = OpenRouterTranscriptionSelection.identifier(for: id)
        guard OpenRouterTranscriptionSelection.modelID(from: selectionID) != nil else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: container, debugDescription: "Missing model ID")
        }
        name = (try? container.decode(String.self, forKey: .name)).flatMap { $0.isEmpty ? nil : $0 } ?? id
        description = (try? container.decode(String.self, forKey: .description)) ?? ""
        let architecture = try container.decode(OpenRouterAudioArchitecture.self, forKey: .architecture)
        inputModalities = architecture.inputModalities
        outputModalities = architecture.outputModalities
        pricing = (try? container.decode([String: PriceValue].self, forKey: .pricing))?.compactMapValues(\.value) ?? [:]
        supportedParameters = (try? container.decode([String].self, forKey: .supportedParameters)) ?? []
        let voices = (try? container.decode([String].self, forKey: .supportedVoices)) ?? []
        var seenVoices = Set<String>()
        supportedVoices = voices.filter { OpenRouterSpeechSelection.isValidVoice($0) && seenVoices.insert($0).inserted }
        contextLength = (try? container.decode(Int.self, forKey: .contextLength)).flatMap { $0 > 0 ? $0 : nil }
        expirationDate = try? container.decode(String.self, forKey: .expirationDate)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(description, forKey: .description)
        try container.encode(
            OpenRouterAudioArchitecture(inputModalities: inputModalities, outputModalities: outputModalities),
            forKey: .architecture
        )
        try container.encode(pricing, forKey: .pricing)
        try container.encode(supportedParameters, forKey: .supportedParameters)
        try container.encode(supportedVoices, forKey: .supportedVoices)
        try container.encodeIfPresent(contextLength, forKey: .contextLength)
        try container.encodeIfPresent(expirationDate, forKey: .expirationDate)
    }
}

struct OpenRouterAudioModelResponse: Decodable {
    let data: [OpenRouterAudioModel]

    private enum CodingKeys: String, CodingKey { case data }

    private struct Entry: Decodable {
        let model: OpenRouterAudioModel?

        init(from decoder: Decoder) throws {
            model = try? OpenRouterAudioModel(from: decoder)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let entries = try container.decode([Entry].self, forKey: .data)
        var identifiers = Set<String>()
        data = entries.compactMap(\.model).filter {
            $0.capability != nil && identifiers.insert($0.id).inserted
        }
        // Empty means retired. Unreadable entries or an ignored modality filter must not erase a good cache.
        if !entries.isEmpty && data.isEmpty {
            throw OpenRouterAudioCatalogError.invalidResponse
        }
    }
}

private struct OpenRouterAudioArchitecture: Codable {
    let inputModalities: [String]
    let outputModalities: [String]

    enum CodingKeys: String, CodingKey {
        case inputModalities = "input_modalities"
        case outputModalities = "output_modalities"
    }
}
