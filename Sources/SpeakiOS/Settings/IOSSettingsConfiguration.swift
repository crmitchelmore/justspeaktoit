#if os(iOS)
import Foundation
import SpeakCore

/// Reads, validates and applies the iPhone's raw settings configuration
/// (issue #1608) for the raw editor. Every iOS schema key has one binding; a
/// document is applied all or none. API keys appear only as whether each is
/// stored.
@MainActor
final class IOSSettingsConfiguration {
    typealias JSONValue = AnyCodable.JSONValue

    /// `UserDefaults` key for settings another platform owns: kept so an
    /// imported document exports again without loss, never applied here.
    static let foreignSettingsDefaultsKey = "rawConfiguration.foreignSettings"

    struct Binding {
        let read: @MainActor (AppSettings) -> JSONValue
        /// Nil for read-only fields, which the validator never lets through.
        let write: (@MainActor (AppSettings, JSONValue) -> Void)?
    }

    struct ApplyError: Error, Equatable {
        let issues: [SettingsIssue]
    }

    private let settings: AppSettings
    private let hasAPIKey: @MainActor (String) async -> Bool

    init(settings: AppSettings, hasAPIKey: @escaping @MainActor (String) async -> Bool) {
        self.settings = settings
        self.hasAPIKey = hasAPIKey
    }

    convenience init(settings: AppSettings = .shared) {
        self.init(settings: settings) { [storage = settings.secrets.storage] in
            await storage.hasSecret(identifier: $0)
        }
    }

    // MARK: Reading

    func currentValues() -> [String: JSONValue] {
        Self.bindings.mapValues { $0.read(settings) }
    }

    /// Current values, preserved foreign keys and which API keys are stored.
    func document() async -> SettingsDocument {
        var values = foreignSettings()
        values.merge(currentValues()) { _, current in current }
        var apiKeys: [String: Bool] = [:]
        for identifier in AppSettings.syncedAPIKeys.map(\.identifier).sorted() {
            apiKeys[identifier] = await hasAPIKey(identifier)
        }
        return SettingsDocument(platform: SettingsSchemaPlatform.iOS.rawValue, settings: values, apiKeys: apiKeys)
    }

    /// Every schema default; fields without one and read-only fields keep their value.
    func defaultsDocument() -> SettingsDocument {
        var values = currentValues()
        for field in SettingsSchema.fields(for: .iOS) where !field.isReadOnly {
            if let value = field.defaultValue { values[field.key] = value }
        }
        return SettingsDocument(platform: SettingsSchemaPlatform.iOS.rawValue, settings: values)
    }

    // MARK: Validating and applying

    func validationContext(ignoringReadOnly: Bool = false) -> SettingsValidationContext {
        var context = SettingsValidationContext(
            currentValues: currentValues(),
            additionalModelIDs: [
                .liveTranscription: [settings.selectedModel],
                .postProcessing: [settings.postProcessingModel]
            ],
            ignoresReadOnlyChanges: ignoringReadOnly
        )
        context.platform = .iOS
        return context
    }

    /// Validates a whole document. Read-only values that differ (for example
    /// from another iPhone) are kept with a warning instead of failing.
    func validate(document: SettingsDocument) -> SettingsValidationReport {
        var report = SettingsValidator.validate(document, context: validationContext(ignoringReadOnly: true))
        report.errors += hostIssues(report.changes)
        return report
    }

    func validate(changes: [String: JSONValue]) -> SettingsValidationReport {
        var report = SettingsValidator.validate(settings: changes, context: validationContext())
        report.errors += hostIssues(report.changes)
        return report
    }

    /// Applies a valid report all or none: if any setting reads back
    /// differently, every setting is restored. Foreign keys are remembered.
    func apply(_ report: SettingsValidationReport, foreign: [String: JSONValue] = [:]) throws {
        guard report.isValid else { throw ApplyError(issues: report.errors) }
        let snapshot = currentValues()
        for key in Self.applyOrder(report.changes.keys) {
            guard let value = report.changes[key] else { continue }
            Self.bindings[key]?.write?(settings, value)
        }
        let after = currentValues()
        let mismatched = report.changes.keys.sorted().filter { after[$0] != report.changes[$0] }
        guard mismatched.isEmpty else {
            restore(snapshot)
            throw ApplyError(issues: mismatched.map {
                SettingsIssue(
                    path: "settings.\($0)", message: "The app did not accept this value; nothing was changed.")
            })
        }
        if !foreign.isEmpty {
            var stored = foreignSettings()
            stored.merge(foreign) { _, new in new }
            storeForeignSettings(stored)
        }
    }

    static func foreignValues(of document: SettingsDocument, report: SettingsValidationReport) -> [String: JSONValue] {
        document.settings.filter { report.ignoredKeys.contains($0.key) }
    }

    private func restore(_ snapshot: [String: JSONValue]) {
        for key in Self.applyOrder(snapshot.keys) {
            guard let value = snapshot[key], Self.bindings[key]?.read(settings) != value else { continue }
            Self.bindings[key]?.write?(settings, value)
        }
    }

    /// Checks the schema cannot express: models this build can run, and the
    /// clipboard lifetimes the picker offers.
    private func hostIssues(_ changes: [String: JSONValue]) -> [SettingsIssue] {
        var issues: [SettingsIssue] = []
        if case .string(let model)? = changes["selectedModel"],
           !AppleLocalModels.isAppleSpeechModel(model), !AppSettings.selectableLiveModelIDs.contains(model) {
            issues.append(.init(path: "settings.selectedModel", message: "\"\(model)\" cannot stream on this device."))
        }
        if case .string(let model)? = changes["batchTranscriptionModel"],
           !AppSettings.supportedBatchModels.contains(where: { $0.id == model }) {
            issues.append(.init(
                path: "settings.batchTranscriptionModel", message: "\"\(model)\" cannot transcribe on this device."))
        }
        if case .string(let model)? = changes["postProcessingModel"],
           !AppSettings.postProcessingModels.contains(where: { $0.id == model }),
           CleanupModelSelection.modelID(from: model) == nil {
            issues.append(.init(path: "settings.postProcessingModel", message: "\"\(model)\" cannot run on this device."))
        }
        if case .int(let seconds)? = changes["transcriptClipboardLifetime"],
           TranscriptClipboardLifetime(rawValue: seconds) == nil {
            let allowed = TranscriptClipboardLifetime.allCases.map { String($0.rawValue) }.joined(separator: ", ")
            issues.append(.init(path: "settings.transcriptClipboardLifetime", message: "Must be one of: \(allowed)."))
        }
        return issues
    }

    /// Models and modes first, then the cleanup switches that depend on them.
    private static func applyOrder<Keys: Sequence>(_ keys: Keys) -> [String] where Keys.Element == String {
        let late = ["postProcessingEnabled", "autoPostProcess"]
        let sorted = keys.sorted()
        return sorted.filter { !late.contains($0) } + late.filter(sorted.contains)
    }

    private func foreignSettings() -> [String: JSONValue] {
        guard let data = settings.defaults.data(forKey: Self.foreignSettingsDefaultsKey),
              let decoded = try? JSONDecoder().decode(AnyCodable.self, from: data),
              case .object(let values) = decoded.storage
        else { return [:] }
        return values.filter { SettingsSchema.field(forKey: $0.key, platform: .iOS) == nil }
    }

    private func storeForeignSettings(_ values: [String: JSONValue]) {
        guard let data = try? JSONEncoder().encode(AnyCodable(.object(values))) else { return }
        settings.defaults.set(data, forKey: Self.foreignSettingsDefaultsKey)
    }
}

// MARK: - Bindings

extension IOSSettingsConfiguration {
    /// One read/write binding per iOS schema key.
    static let bindings: [String: Binding] = {
        var table: [String: Binding] = [:]
        func bool(_ key: String, _ path: ReferenceWritableKeyPath<AppSettings, Bool>) {
            table[key] = Binding(read: { .bool($0[keyPath: path]) }, write: { settings, value in
                if case .bool(let bool) = value { settings[keyPath: path] = bool }
            })
        }
        func string(_ key: String, _ path: ReferenceWritableKeyPath<AppSettings, String>) {
            table[key] = Binding(read: { .string($0[keyPath: path]) }, write: { settings, value in
                if case .string(let string) = value { settings[keyPath: path] = string }
            })
        }
        func choice<Choice: RawRepresentable>(
            _ key: String, _ path: ReferenceWritableKeyPath<AppSettings, Choice>
        ) where Choice.RawValue == String {
            table[key] = Binding(read: { .string($0[keyPath: path].rawValue) }, write: { settings, value in
                if case .string(let raw) = value, let choice = Choice(rawValue: raw) {
                    settings[keyPath: path] = choice
                }
            })
        }

        // Transcription
        choice("transcriptionMode", \.transcriptionMode)
        choice("rememberedRemoteTranscriptionMode", \.rememberedRemoteTranscriptionMode)
        string("selectedModel", \.selectedModel)
        string("batchTranscriptionModel", \.batchTranscriptionModel)
        string("preferredLocaleIdentifier", \.preferredLocaleIdentifier)
        string("transcriptionKeywords", \.transcriptionKeywords)
        bool("upgradeOfflineTranscriptsWhenOnline", \.upgradeOfflineTranscriptsWhenOnline)
        bool("keepAudioOnCancel", \.keepAudioOnCancel)

        // Recording, results and display
        choice("visualDensity", \.visualDensity)
        bool("autoStartRecording", \.autoStartRecording)
        bool("handsFreeDictationEnabled", \.handsFreeDictationEnabled)
        bool("liveActivitiesEnabled", \.liveActivitiesEnabled)
        table["transcriptReadyNotificationsEnabled"] = Binding(
            read: { .bool($0.transcriptReadyNotificationsEnabled) }, write: nil)
        choice("hardwareTriggerDestination", \.hardwareTriggerDestination)
        bool("autoStopOnSilenceEnabled", \.autoStopOnSilenceEnabled)
        table["autoStopSilenceSeconds"] = Binding(
            read: { .double($0.autoStopSilenceSeconds) },
            write: { settings, value in
                switch value {
                case .double(let seconds): settings.autoStopSilenceSeconds = seconds
                case .int(let seconds): settings.autoStopSilenceSeconds = Double(seconds)
                default: break
                }
            })
        table["transcriptClipboardLifetime"] = Binding(
            read: { .int($0.transcriptClipboardLifetime.rawValue) },
            write: { settings, value in
                if case .int(let seconds) = value, let lifetime = TranscriptClipboardLifetime(rawValue: seconds) {
                    settings.transcriptClipboardLifetime = lifetime
                }
            })
        bool("transcriptAllowsUniversalClipboard", \.transcriptAllowsUniversalClipboard)

        // Cleanup
        bool("postProcessingEnabled", \.postProcessingEnabled)
        string("postProcessingModel", \.postProcessingModel)
        bool("cleanupModelDiscoveryEnabled", \.cleanupModelDiscoveryEnabled)
        bool("autoPostProcess", \.autoPostProcess)
        return table
    }()
}
#endif
