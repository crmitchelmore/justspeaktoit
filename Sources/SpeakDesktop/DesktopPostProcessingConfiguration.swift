import Foundation
import SpeakCore

/// Transfer projections, not another runtime preference store. Applied values
/// leave `DesktopConfiguration`; unsupported choices remain there losslessly.
public enum DesktopPostProcessingConfiguration {
    private static let enabledKey = ApplicationPreferenceKey.postProcessingEnabled.rawValue
    private static let modelKey = ApplicationPreferenceKey.postProcessingModel.rawValue
    /// The Mac's custom prompt is not a DefaultsKey / ApplicationPreferenceKey.
    public static let customPromptKey = "postProcessingSystemPrompt"
    private static let directivesKey = ApplicationPreferenceKey.postProcessingIncludeLexiconDirectives.rawValue
    private static let tagsKey = ApplicationPreferenceKey.postProcessingIncludeContextTags.rawValue
    public static let keys: Set<String> = [enabledKey, modelKey, customPromptKey, directivesKey, tagsKey]

    public static func exportOptions(
        _ options: DesktopPostProcessing.Options?, over configuration: DesktopConfiguration
    ) throws -> DesktopConfiguration {
        guard let options else { return configuration }
        var values = configuration.values
        if values[modelKey] == nil { values[modelKey] = AnyCodable(.string(options.modelIdentifier)) }
        if values[enabledKey] == nil { values[enabledKey] = AnyCodable(.bool(options.mode != .disabled)) }
        if values[customPromptKey] == nil { values[customPromptKey] = AnyCodable(.string(options.customPrompt ?? "")) }
        if values[directivesKey] == nil { values[directivesKey] = AnyCodable(.bool(options.includeLexiconDirectives)) }
        if values[tagsKey] == nil { values[tagsKey] = AnyCodable(.bool(options.includeContextTags)) }
        return try DesktopConfiguration(values: values)
    }

    public static func importOptions(
        from configuration: DesktopConfiguration, into options: inout DesktopPostProcessing.Options?
    ) throws -> DesktopConfiguration {
        var values = configuration.values
        guard !keys.isDisjoint(with: values.keys) else { return configuration }
        let model = try text(modelKey, in: values)
        let prompt = try text(customPromptKey, in: values)
        let enabled = try boolean(enabledKey, in: values)
        let directives = try boolean(directivesKey, in: values)
        let tags = try boolean(tagsKey, in: values)
        var changed = options ?? .init()
        if let directives {
            changed.includeLexiconDirectives = directives
            values.removeValue(forKey: directivesKey)
        }
        if let tags {
            changed.includeContextTags = tags
            values.removeValue(forKey: tagsKey)
        }
        if let prompt {
            changed.customPrompt = prompt.isEmpty ? nil : prompt
            values.removeValue(forKey: customPromptKey)
        }
        let selected = (model ?? changed.modelIdentifier).trimmingCharacters(in: .whitespacesAndNewlines)
        if DesktopPostProcessing.mode(for: selected) == .local {
            changed.modelIdentifier = selected
            changed.mode = (enabled ?? (changed.mode != .disabled)) ? .local : .disabled
            values.removeValue(forKey: modelKey)
            values.removeValue(forKey: enabledKey)
        } else if DesktopPostProcessing.isLocalIdentifier(selected) {
            changed.modelIdentifier = selected
            changed.mode = .disabled
        } else if enabled == false {
            // Turning a service off is safe; an imported cloud enable is not
            // permission to access credentials or transmit a transcript.
            changed.mode = .disabled
            values.removeValue(forKey: enabledKey)
        }
        let result = try DesktopConfiguration(values: values)
        options = changed
        return result
    }

    public static func removingMirrors(from configuration: DesktopConfiguration) throws -> DesktopConfiguration {
        try DesktopConfiguration(values: configuration.values.filter { !keys.contains($0.key) })
    }

    private static func text(_ key: String, in values: [String: AnyCodable]) throws -> String? {
        guard let value = values[key] else { return nil }
        guard case .string(let text) = value.storage, text.utf8.count <= 65_535, !text.contains("\0") else {
            throw DesktopConfigurationError.invalidField(key)
        }
        return text
    }

    private static func boolean(_ key: String, in values: [String: AnyCodable]) throws -> Bool? {
        guard let value = values[key] else { return nil }
        guard case .bool(let flag) = value.storage else { throw DesktopConfigurationError.invalidField(key) }
        return flag
    }
}
