import Foundation

/// Reading and changing app settings over automation (`get_configuration`,
/// `set_configuration`). Separate from `AutomationCommandHost` so a host opts in;
/// the dispatcher reports `unsupported_command` for one that does not.
public protocol AutomationConfigurationHost: AutomationCommandHost {
    /// The current settings (optionally narrowed to `keys` and/or `prefix`),
    /// their schema and which API keys are stored. Never returns a secret.
    func automationConfiguration(keys: [String]?, prefix: String?) async throws -> AutomationResult
    /// Validates `changes` against `SettingsSchema` and, unless `dryRun`, applies
    /// all of them or none. Hosts refuse a write the user has not allowed.
    func automationSetConfiguration(
        _ changes: [String: AnyCodable.JSONValue],
        dryRun: Bool
    ) async throws -> AutomationResult
}

extension AutomationLimits {
    /// Keys or changes in one configuration request; the schema is far smaller.
    public static let maxConfigurationKeys = 256
}

/// The result payloads every configuration host returns, so platforms agree.
public enum AutomationConfiguration {
    public typealias JSONValue = AnyCodable.JSONValue

    /// `get_configuration`: the document's sections plus each returned key's schema.
    public static func getResult(_ document: SettingsDocument, keys: [String]?, prefix: String?) -> AutomationResult {
        getResult(document, keys: keys, prefix: prefix, platform: .macOS)
    }

    public static func getResult(
        _ document: SettingsDocument, keys: [String]?, prefix: String?, platform: SettingsSchemaPlatform
    ) -> AutomationResult {
        let filtered = document.filtered(keys: keys, prefix: prefix)
        let schemaKeys = SettingsSchema.keys(for: platform).filter {
            (keys.map(Set.init)?.contains($0) ?? true) && (prefix.map($0.hasPrefix) ?? true)
        }
        guard case .object(var object) = filtered.jsonValue else { return AutomationResult() }
        object["schema"] = .object(SettingsSchema.describe(keys: schemaKeys, platform: platform))
        var result = AutomationResult()
        result.configuration = AnyCodable(.object(object))
        return result
    }

    /// `set_configuration`: what changed (or would change), and any warnings.
    /// A report with errors throws instead, listing every issue.
    public static func setResult(_ report: SettingsValidationReport, dryRun: Bool) throws -> AutomationResult {
        try self.requireValid(report)
        var result = AutomationResult()
        result.configuration = AnyCodable(.object([
            "dryRun": .bool(dryRun),
            "applied": .bool(!dryRun && !report.changes.isEmpty),
            "changes": .object(report.changes),
            "ignoredKeys": .array(report.ignoredKeys.map { .string($0) }),
            "warnings": .array(report.warnings.map { .string($0.description) })
        ]))
        return result
    }

    public static func requireValid(_ report: SettingsValidationReport) throws {
        guard report.isValid else {
            throw AutomationError(
                code: .invalidArgument,
                message: "Configuration not changed. " + report.errors.map(\.description).joined(separator: "; "))
        }
    }

    /// `set_configuration` without the user's opt-in to automated writes.
    public static let writesNotAllowed = writesNotAllowed(location: "Settings → General → Automation")

    /// `set_configuration` without the opt-in, naming where the host shows it.
    public static func writesNotAllowed(location: String) -> AutomationError {
        AutomationError(
            code: .unsupportedCommand,
            message: "Changing settings over automation is turned off. Turn on \"Allow automation to change "
                + "settings\" under \(location), or pass dry_run to only validate.")
    }
}

extension AutomationRequest {
    /// Keeps configuration fields on the configuration commands only.
    func validateConfigurationFields() throws {
        let hasFilters = self.keys != nil || self.prefix != nil
        let hasChanges = self.changes != nil || self.dryRun != nil
        let others = self.path != nil || self.limit != nil || self.profile != nil || self.provider != nil
        switch self.command {
        case .getConfiguration:
            guard !hasChanges, !others else {
                throw AutomationError(
                    code: .invalidArgument, message: "get_configuration accepts only keys and prefix.")
            }
            try Self.validateKeys(self.keys ?? [])
            if let prefix, prefix.count > AutomationLimits.maxIdentifierLength {
                throw AutomationError(code: .invalidArgument, message: "prefix is too long.")
            }
        case .setConfiguration:
            guard !hasFilters, !others else {
                throw AutomationError(
                    code: .invalidArgument, message: "set_configuration accepts only changes and dry_run.")
            }
            guard let changes, !changes.isEmpty else {
                throw AutomationError(code: .invalidArgument, message: "set_configuration requires changes.")
            }
            try Self.validateKeys(Array(changes.keys))
        default:
            guard !hasFilters, !hasChanges else {
                throw AutomationError(
                    code: .invalidArgument, message: "Configuration fields require a configuration command.")
            }
        }
    }

    private static func validateKeys(_ keys: [String]) throws {
        guard keys.count <= AutomationLimits.maxConfigurationKeys,
              keys.allSatisfy({ !$0.isEmpty && $0.count <= AutomationLimits.maxIdentifierLength }) else {
            throw AutomationError(
                code: .invalidArgument,
                message: "Use at most \(AutomationLimits.maxConfigurationKeys) setting keys of "
                    + "1-\(AutomationLimits.maxIdentifierLength) characters.")
        }
    }
}
