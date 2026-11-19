import Foundation

/// Explicit discovered selections have a stable namespace, independent of cache lifetime.
/// Turning discovery off never rewrites an already selected model.
public enum CleanupModelSelection {
    public static let prefix = "openrouter/cleanup/"
    public static let preferenceKey = ApplicationPreferenceKey.cleanupModelDiscoveryEnabled.rawValue
    public static let settingTitle = "Discover OpenAI cleanup models via OpenRouter"

    public static func modelID(from selection: String) -> String? {
        guard selection.hasPrefix(prefix) else { return nil }
        let model = String(selection.dropFirst(prefix.count))
        return trustedModelID(model) ? model : nil
    }

    static func trustedModelID(_ model: String) -> Bool {
        let parts = model.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-._")
        return model.utf8.count <= 200 && parts.count == 2 && parts[0] == "openai"
            && !parts[1].isEmpty && parts[1].unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    static func requestModel(_ selection: String) throws -> String {
        guard selection.hasPrefix(prefix) else { return selection }
        guard let model = modelID(from: selection) else { throw CleanupModelDiscoveryError.invalidCatalogue }
        return model
    }

    public static func retainedOption(_ selection: String) -> ModelCatalog.Option? {
        guard let model = modelID(from: selection) else { return nil }
        return .init(id: selection, displayName: model + " (saved discovery)",
                     description: "Your saved OpenRouter choice. Availability and pricing may have changed.")
    }
}

/// Only validated metadata is retained; provider descriptions and unknown fields are discarded.
public struct DiscoveredCleanupModel: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let inputPrice: Double?
    public let outputPrice: Double?
    public let contextLength: Int?

    public var selectionID: String { CleanupModelSelection.prefix + id }
    public var option: ModelCatalog.Option {
        let pricing: ModelCatalog.Pricing?
        if let inputPrice, let outputPrice {
            pricing = .init(promptPerMTokens: inputPrice, completionPerMTokens: outputPrice)
        } else { pricing = nil }
        return .init(id: selectionID, displayName: name + " (discovered)",
                     description: "OpenAI via OpenRouter. Unqualified for cleanup; "
                        + "base rates may vary by context/provider.",
                     pricing: pricing, contextLength: contextLength)
    }

    var isValid: Bool {
        CleanupModelSelection.trustedModelID(id) && !name.isEmpty && name.utf8.count <= 160
            && name.rangeOfCharacter(from: .controlCharacters) == nil
            && [inputPrice, outputPrice].allSatisfy { price in
                price.map { $0.isFinite && $0 >= 0 && $0 <= 1_000_000 } ?? true
            }
            && (contextLength.map { $0 > 0 && $0 <= 100_000_000 } ?? true)
    }
}

enum CleanupModelDiscoveryError: Error { case invalidCatalogue, httpStatus(Int) }

struct CleanupModelResponse: Decodable {
    let data: [DiscoveredCleanupModel]
    enum CodingKeys: String, CodingKey { case data }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let entries = try container.decode([CleanupModelEntry].self, forKey: .data)
        guard entries.count <= 4096 else { throw CleanupModelDiscoveryError.invalidCatalogue }
        var seen = Set<String>()
        data = Array(entries.compactMap(\.model).filter { seen.insert($0.id).inserted }
            .sorted { $0.id < $1.id }.prefix(256))
    }

}

private struct CleanupModelEntry: Decodable {
    let model: DiscoveredCleanupModel?
    init(from decoder: Decoder) throws {
        model = try? Self.read(decoder)
    }
    private enum Keys: String, CodingKey {
        case id, name, architecture, pricing, endpoints
        case expiration = "expiration_date"
        case context = "context_length"
    }
    private struct Architecture: Decodable {
        let input_modalities: [String] // swiftlint:disable:this identifier_name
        let output_modalities: [String] // swiftlint:disable:this identifier_name
    }
    private struct Rates: Decodable { let prompt: String?; let completion: String? }
    private static func read(_ decoder: Decoder) throws -> DiscoveredCleanupModel {
        let value = try decoder.container(keyedBy: Keys.self)
        let id = try value.decode(String.self, forKey: .id)
        let architecture = try value.decode(Architecture.self, forKey: .architecture)
        let endpoints = try value.decode([String].self, forKey: .endpoints)
        guard CleanupModelSelection.trustedModelID(id), architecture.input_modalities.contains("text"),
              architecture.output_modalities == ["text"],
              endpoints.contains("/api/v1/chat/completions"),
              (try value.decodeIfPresent(String.self, forKey: .expiration)) == nil else {
            throw CleanupModelDiscoveryError.invalidCatalogue
        }
        let prices = try? value.decode(Rates.self, forKey: .pricing)
        let name = (try? value.decode(String.self, forKey: .name)) ?? id
        let model = DiscoveredCleanupModel(
            id: id, name: name, inputPrice: price(prices?.prompt), outputPrice: price(prices?.completion),
            contextLength: (try? value.decode(Int.self, forKey: .context)).flatMap { $0 > 0 ? $0 : nil }
        )
        guard model.isValid else { throw CleanupModelDiscoveryError.invalidCatalogue }
        return model
    }
    private static func price(_ text: String?) -> Double? {
        guard let text, let value = Double(text), value.isFinite, value >= 0,
              value <= 1 else { return nil }
        guard let decimal = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        return NSDecimalNumber(decimal: decimal * 1_000_000).doubleValue
    }
}
