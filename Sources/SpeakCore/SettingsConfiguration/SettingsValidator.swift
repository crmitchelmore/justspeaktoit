import Foundation

/// What the validator compares a proposed configuration against.
public struct SettingsValidationContext: Sendable {
    public typealias JSONValue = AnyCodable.JSONValue

    /// The host's current value for every schema key it binds.
    public var currentValues: [String: JSONValue]
    /// Model identifiers the host also accepts, such as downloaded local models
    /// or the host's preferred Apple speech engine.
    public var additionalModelIDs: [SettingsModelCatalogue: Set<String>]
    /// Allowed values the host narrows at runtime, for example output methods
    /// a distribution channel cannot use.
    public var allowedValuesOverride: [String: [String]]
    /// When true, a read-only value that differs from the current one is kept
    /// unchanged with a warning instead of failing, so a whole exported
    /// document (for example from another Mac) can still be imported.
    public var ignoresReadOnlyChanges: Bool
    /// The host whose schema the settings are checked against.
    public var platform: SettingsSchemaPlatform = .macOS

    public init(
        currentValues: [String: JSONValue],
        additionalModelIDs: [SettingsModelCatalogue: Set<String>] = [:],
        allowedValuesOverride: [String: [String]] = [:],
        ignoresReadOnlyChanges: Bool = false
    ) {
        self.currentValues = currentValues
        self.additionalModelIDs = additionalModelIDs
        self.allowedValuesOverride = allowedValuesOverride
        self.ignoresReadOnlyChanges = ignoresReadOnlyChanges
    }
}

/// The outcome of validating a proposed configuration. A host applies
/// `changes` only when `errors` is empty, and applies all of them or none.
public struct SettingsValidationReport: Equatable, Sendable {
    public typealias JSONValue = AnyCodable.JSONValue

    public var errors: [SettingsIssue]
    public var warnings: [SettingsIssue]
    /// Canonical values that differ from the current ones.
    public var changes: [String: JSONValue]
    /// Keys another platform owns: kept in documents, never applied here.
    public var ignoredKeys: [String]

    public init(
        errors: [SettingsIssue] = [],
        warnings: [SettingsIssue] = [],
        changes: [String: JSONValue] = [:],
        ignoredKeys: [String] = []
    ) {
        self.errors = errors
        self.warnings = warnings
        self.changes = changes
        self.ignoredKeys = ignoredKeys
    }

    public var isValid: Bool { self.errors.isEmpty }
}

/// Checks a raw configuration against `SettingsSchema`: types, ranges, allowed
/// values, catalogue model identifiers, read-only fields and cross-field rules.
public enum SettingsValidator {
    public typealias JSONValue = AnyCodable.JSONValue

    public static func validate(
        _ document: SettingsDocument,
        context: SettingsValidationContext
    ) -> SettingsValidationReport {
        var report = self.validate(settings: document.settings, context: context)
        if let platform = document.platform,
           SettingsSchemaPlatform(rawValue: platform).map({ !$0.sharesSettings(with: context.platform) }) ?? true {
            report.warnings.insert(
                .init(path: "platform", message: "Written by \(platform); settings it does not share are ignored."),
                at: 0)
        }
        return report
    }

    public static func validate(
        settings: [String: JSONValue],
        context: SettingsValidationContext
    ) -> SettingsValidationReport {
        var report = SettingsValidationReport()
        for key in settings.keys.sorted() {
            guard let value = settings[key] else { continue }
            let path = "settings.\(key)"
            guard let field = SettingsSchema.field(forKey: key, platform: context.platform) else {
                if SettingsSchema.knownKeys.contains(key) {
                    report.ignoredKeys.append(key)
                    report.warnings.append(
                        .init(path: path, message: "Not a setting on this platform; kept but ignored."))
                } else {
                    report.errors.append(.init(path: path, message: "Unknown setting."))
                }
                continue
            }
            switch self.check(value, field: field, context: context) {
            case .failure(let message):
                report.errors.append(.init(path: path, message: message))
            case .keptReadOnly:
                report.warnings.append(.init(path: path, message: "Read-only here; kept the current value."))
            case .success(let canonical):
                let current = context.currentValues[key].map { self.canonicalNumber($0, kind: field.kind) }
                if canonical != current {
                    report.changes[key] = canonical
                }
            }
        }
        report.errors += self.crossFieldIssues(report.changes, context: context)
        return report
    }

    private enum Outcome {
        case success(JSONValue)
        case failure(String)
        case keptReadOnly
    }

    private static func check(_ value: JSONValue, field: SettingsSchemaField, context: SettingsValidationContext)
        -> Outcome {
        guard let canonical = self.typed(value, kind: field.kind) else {
            return .failure("Expected \(self.kindName(field.kind)).")
        }
        let current = context.currentValues[field.key].map { self.canonicalNumber($0, kind: field.kind) }
        if field.isReadOnly {
            if canonical == current { return .success(canonical) }
            return context.ignoresReadOnlyChanges
                ? .keptReadOnly
                : .failure("Read-only here; change it in the app's Settings.")
        }
        if let allowed = context.allowedValuesOverride[field.key] ?? field.allowedValues,
           case .string(let choice) = canonical, !allowed.contains(choice) {
            return .failure("Must be one of: \(allowed.joined(separator: ", ")).")
        }
        if let range = field.range, let number = self.number(canonical), !range.contains(number) {
            return .failure("Must be between \(self.format(range.lowerBound)) and \(self.format(range.upperBound)).")
        }
        if let catalogue = field.modelCatalogue, case .string(let modelID) = canonical, canonical != current,
           !self.isKnownModel(modelID, catalogue: catalogue, context: context) {
            return .failure("\"\(modelID)\" is not in the \(catalogue.rawValue) model catalogue.")
        }
        return .success(canonical)
    }

    /// The value in its canonical JSON form, or nil when it has the wrong type.
    private static func typed(_ value: JSONValue, kind: SettingsValueKind) -> JSONValue? {
        switch (kind, value) {
        case (.boolean, .bool), (.string, .string), (.enumeration, .string),
             (.optionalString, .string), (.optionalString, .null), (.object, .object):
            return value
        case (.integer, .int):
            return value
        case (.integer, .double(let number)):
            return number.rounded() == number && abs(number) < 1e15 ? .int(Int(number)) : nil
        case (.number, .int), (.number, .double):
            return self.canonicalNumber(value, kind: kind)
        case (.stringArray, .array(let items)):
            return items.allSatisfy { if case .string = $0 { return true } else { return false } } ? value : nil
        case (.stringMap, .object(let items)):
            return items.values.allSatisfy { if case .string = $0 { return true } else { return false } } ? value : nil
        default:
            return nil
        }
    }

    private static func canonicalNumber(_ value: JSONValue, kind: SettingsValueKind) -> JSONValue {
        if kind == .number, case .int(let int) = value { return .double(Double(int)) }
        return value
    }

    private static func number(_ value: JSONValue) -> Double? {
        switch value {
        case .int(let int): return Double(int)
        case .double(let double): return double
        default: return nil
        }
    }

    public static func isKnownModel(
        _ modelID: String,
        catalogue: SettingsModelCatalogue,
        context: SettingsValidationContext
    ) -> Bool {
        if context.additionalModelIDs[catalogue]?.contains(modelID) == true { return true }
        switch catalogue {
        case .liveTranscription:
            return AppleLocalModels.isAppleSpeechModel(modelID)
                || ModelCatalog.liveTranscription.contains { $0.id == modelID }
        case .batchTranscription:
            return AppleLocalModels.isAppleSpeechModel(modelID)
                || ModelCatalog.batchTranscription.contains { $0.id == modelID }
        case .localTranscription:
            return ModelCatalog.localTranscription.contains { $0.option.id == modelID }
        case .postProcessing:
            return self.isPostProcessingModel(modelID)
        case .livePolish:
            return modelID.isEmpty || self.isPostProcessingModel(modelID)
        }
    }

    private static func isPostProcessingModel(_ modelID: String) -> Bool {
        ModelCatalog.postProcessing.contains { $0.id == modelID }
            || (!modelID.isEmpty && ModelCatalog.normalizedPostProcessingModel(modelID) == modelID)
    }

    /// Rules spanning settings, checked against the merged result when a change
    /// touches one of them.
    private static func crossFieldIssues(
        _ changes: [String: JSONValue],
        context: SettingsValidationContext
    ) -> [SettingsIssue] {
        func merged(_ key: String) -> JSONValue? { changes[key] ?? context.currentValues[key] }
        var issues: [SettingsIssue] = []

        let speedKeys: Set = ["speedMode", "transcriptionMode", "liveTranscriptionModel"]
        if !speedKeys.isDisjoint(with: changes.keys),
           case .string(let speed)? = merged("speedMode"), speed == SpeedModeID.livePolish.rawValue {
            if merged("transcriptionMode") != .string("liveNative") {
                issues.append(.init(
                    path: "settings.speedMode",
                    message: "Auto-Clean needs transcriptionMode \"liveNative\"."))
            } else if case .string(let model)? = merged("liveTranscriptionModel"),
                      !ModelCatalog.liveCapabilities(for: model).supportedSpeedModes.contains(.livePolish) {
                issues.append(.init(
                    path: "settings.speedMode",
                    message: "The live model \"\(model)\" does not support Auto-Clean; choose one that does "
                        + "or set speedMode to \"instant\"."))
            }
        }

        let cleanupKeys: Set = ["postProcessingEnabled", "speedMode"]
        if !cleanupKeys.isDisjoint(with: changes.keys), merged("postProcessingEnabled") == .bool(true),
           let speed = merged("speedMode"), speed != .string(SpeedModeID.instant.rawValue) {
            issues.append(.init(
                path: "settings.postProcessingEnabled",
                message: "Cleanup cannot run with Auto-Clean; set speedMode to \"instant\" or this to false."))
        }
        return issues
    }

    private static func kindName(_ kind: SettingsValueKind) -> String {
        switch kind {
        case .boolean: return "true or false"
        case .integer: return "a whole number"
        case .number: return "a number"
        case .string, .enumeration: return "a string"
        case .optionalString: return "a string or null"
        case .stringArray: return "an array of strings"
        case .stringMap: return "an object of strings"
        case .object: return "an object"
        }
    }

    private static func format(_ number: Double) -> String {
        number.rounded() == number ? String(Int(number)) : String(number)
    }
}
