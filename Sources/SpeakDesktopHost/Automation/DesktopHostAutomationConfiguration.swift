import Foundation
import SpeakCore
import SpeakDesktop

/// `get_configuration` and `set_configuration` (`speak config`, MCP) on Windows
/// and Linux. The schema is `SettingsSchema.fields(for: .windows)`, derived from
/// `DesktopConfiguration.fields`; a write goes through the same save path as the
/// Preferences editor and only after the local "Allow automation to change
/// settings" grant.
extension DesktopHostController: AutomationConfigurationHost where Platform: DesktopHostAutomationPlatform {
    package func automationConfiguration(keys: [String]?, prefix: String?) async throws -> AutomationResult {
        AutomationConfiguration.getResult(
            try automationSettingsDocument(), keys: keys, prefix: prefix, platform: Self.settingsSchemaPlatform
        )
    }

    package func automationSetConfiguration(
        _ changes: [String: AnyCodable.JSONValue], dryRun: Bool
    ) async throws -> AutomationResult {
        let current = try automationSettingsValues()
        let writesAllowed = current[ApplicationPreferenceKey.allowAutomationConfigurationChanges.rawValue]
            == .bool(true)
        guard dryRun || writesAllowed else {
            throw AutomationConfiguration.writesNotAllowed(location: "Preferences → General")
        }
        var context = SettingsValidationContext(currentValues: current)
        context.platform = Self.settingsSchemaPlatform
        let report = SettingsValidator.validate(settings: changes, context: context)
        try AutomationConfiguration.requireValid(report)
        let previous = try configurationForNativeEditor()
        let candidate: DesktopConfiguration
        do {
            candidate = try Self.applyingAutomationChanges(report.changes, to: previous)
        } catch let error as DesktopConfigurationError {
            throw AutomationError(code: .invalidArgument, message: "Configuration not changed. \(error)")
        }
        if !dryRun, !report.changes.isEmpty {
            guard settingsDocumentCanSave else {
                throw AutomationError(
                    code: .invalidArgument, message: "Configuration not changed. Finish dictation first.")
            }
            try await saveSettingsDocumentChanges(
                candidate, from: previous, status: "Configuration changed by automation."
            )
        }
        return try AutomationConfiguration.setResult(report, dryRun: dryRun)
    }
}

/// The settings document shared by automation and the raw configuration
/// editor (Preferences › General › Edit raw configuration).
extension DesktopHostController {
    package nonisolated static var settingsSchemaPlatform: SettingsSchemaPlatform {
        switch Platform.nativeConfigurationPlatform {
        case .windows: return .windows
        case .linux: return .linux
        case nil:
            #if os(Windows)
            return .windows
            #else
            return .linux
            #endif
        }
    }

    /// False while a recording or other work would race a save.
    var settingsDocumentCanSave: Bool { !closed && !busy && recording == nil }

    /// Saves a validated candidate through the Preferences save path.
    func saveSettingsDocumentChanges(
        _ candidate: DesktopConfiguration, from previous: DesktopConfiguration, status: String
    ) async throws {
        let reconciled = try await reconcilingPronunciationSelection(candidate, from: previous, editor: nil)
        try await persistConfiguration(reconciled, intent: .persistOnly, status: status)
    }

    /// The settings document automation reads: every desktop schema key with
    /// its current (or default) value, and which API keys this device stores.
    /// Secrets are never read; the tracked-key index only says which are set.
    func automationSettingsDocument() throws -> SettingsDocument {
        var apiKeys: [String: Bool] = [:]
        for identifier in trackedAPIKeyIdentifiers().identifiers { apiKeys[identifier] = true }
        return SettingsDocument(
            platform: Self.settingsSchemaPlatform.rawValue, settings: try automationSettingsValues(), apiKeys: apiKeys
        )
    }

    func automationSettingsValues() throws -> [String: AnyCodable.JSONValue] {
        let configuration = try configurationForNativeEditor()
        var values: [String: AnyCodable.JSONValue] = [:]
        for field in DesktopConfiguration.fields {
            guard let schema = SettingsSchema.field(forKey: field.key, platform: Self.settingsSchemaPlatform)
            else { continue }
            if DesktopConfiguration.modulatePreferenceKeys.contains(field.key) {
                if let stored = configuration.values[field.key] { values[field.key] = stored.storage }
                continue
            }
            var value = configuration.value(for: field).storage
            if schema.kind == .integer, case .double(let number) = value { value = .int(Int(number)) }
            values[field.key] = value
        }
        let serverKey = ApplicationPreferenceKey.enableAutomationServer.rawValue
        values[serverKey] = configuration.values[serverKey]?.storage ?? .bool(false)
        return values
    }

    /// Merges validated changes into the editor's configuration. Building a
    /// `DesktopConfiguration` is the final check, so nothing is saved unless the
    /// whole result is valid.
    static func applyingAutomationChanges(
        _ changes: [String: AnyCodable.JSONValue], to previous: DesktopConfiguration
    ) throws -> DesktopConfiguration {
        var values = previous.values
        for (key, value) in changes { values[key] = AnyCodable(value) }
        return try DesktopConfiguration(values: values)
    }
}
