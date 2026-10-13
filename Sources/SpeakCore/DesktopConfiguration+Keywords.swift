import Foundation

extension DesktopConfiguration {
    public static var supportedKeys: Set<String> {
        Set(fields.map(\.key)).union([
            ApplicationPreferenceKey.transcriptionKeywordsLastReconciled.rawValue,
            ApplicationPreferenceKey.recoveredTranscriptionKeywords.rawValue
        ])
    }

    public var recoveredKeywords: [String] {
        guard case .array(let entries)? = values["recoveredTranscriptionKeywords"]?.storage else { return [] }
        return entries.map {
            guard case .string(let text) = $0 else { preconditionFailure("Invalid validated keyword recovery.") }
            return text
        }
    }

    public func recoveringKeywords(_ selected: String) throws -> Self {
        var recovered = recoveredKeywords
        guard let index = recovered.firstIndex(of: selected) else {
            throw DesktopConfigurationError.invalidField("Recovered keyword edit (refresh preferences)")
        }
        recovered.remove(at: index)
        let active = TranscriptionKeywordPolicy.reconcile(
            canonical: text("transcriptionKeywords"), legacy: selected, lastReconciled: nil
        ).active
        var changed = values
        changed["transcriptionKeywords"] = AnyCodable(.string(active))
        changed["assemblyAIKeyterms"] = AnyCodable(.string(active))
        changed["transcriptionKeywordsLastReconciled"] = AnyCodable(.string(active))
        changed["recoveredTranscriptionKeywords"] = AnyCodable(.array(recovered.map { .string($0) }))
        return try Self(values: changed)
    }

    static func reconciledKeywords(in original: [String: AnyCodable]) throws -> [String: AnyCodable] {
        let last = try keywordText(original["transcriptionKeywordsLastReconciled"])
        var recovered = try recoveryLists(original["recoveredTranscriptionKeywords"])
        guard original["transcriptionKeywords"] != nil || original["assemblyAIKeyterms"] != nil else { return original }
        let result = TranscriptionKeywordPolicy.reconcile(
            canonical: try keywordText(original["transcriptionKeywords"]) ?? "",
            legacy: try keywordText(original["assemblyAIKeyterms"]) ?? "", lastReconciled: last
        )
        _ = try keywordText(AnyCodable(.string(result.active)))
        if let conflict = result.recovered, !recovered.contains(conflict) { recovered.append(conflict) }
        var changed = original
        changed["transcriptionKeywords"] = AnyCodable(.string(result.active))
        changed["assemblyAIKeyterms"] = AnyCodable(.string(result.active))
        changed["transcriptionKeywordsLastReconciled"] = AnyCodable(.string(result.active))
        if !recovered.isEmpty || original["recoveredTranscriptionKeywords"] != nil {
            changed["recoveredTranscriptionKeywords"] = AnyCodable(.array(recovered.map { .string($0) }))
        }
        _ = try recoveryLists(changed["recoveredTranscriptionKeywords"])
        return changed
    }

    private static func keywordText(_ value: AnyCodable?) throws -> String? {
        guard let value else { return nil }
        guard case .string(let text) = value.storage, text.utf8.count <= 65_535, !text.contains("\0") else {
            throw DesktopConfigurationError.invalidField("Keyword reconciliation text")
        }
        return text
    }

    private static func recoveryLists(_ value: AnyCodable?) throws -> [String] {
        guard let value else { return [] }
        guard case .array(let entries) = value.storage, entries.count <= 1_000 else {
            throw DesktopConfigurationError.invalidField("Recovered keyword lists (maximum 1000)")
        }
        return try entries.map { entry in
            try keywordText(AnyCodable(entry)) ?? ""
        }
    }
}
