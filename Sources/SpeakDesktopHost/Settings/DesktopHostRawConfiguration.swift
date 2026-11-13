import Foundation
import SpeakCore
import SpeakDesktop

/// What the raw configuration window asks for. The raw value is the index
/// the native window sends with `DesktopNativeWindowEvent.rawConfiguration`.
package enum DesktopRawConfigurationAction: Int32, CaseIterable, Sendable {
    /// Show the saved settings. Text: ignored.
    case load = 0
    /// Check the editor's JSON. Text: the JSON.
    case validate = 1
    /// Check, then save all of it or none. Text: the JSON.
    case apply = 2
    /// Fill the editor with defaults without saving. Text: ignored.
    case defaults = 3
    /// Read a file into the editor and check it. Text: the file's path.
    case importFile = 4
    /// Write the editor's JSON to a file. Text: the path, a newline, then the JSON.
    case export = 5
}

/// What the raw configuration window shows after an action.
package struct DesktopRawConfigurationOutcome: Equatable, Sendable {
    /// New editor text, or nil to keep what the user typed.
    package var text: String?
    package var status: String
    package var errors: [String]
    package var warnings: [String]

    package init(text: String? = nil, status: String, errors: [String] = [], warnings: [String] = []) {
        self.text = text
        self.status = status
        self.errors = errors
        self.warnings = warnings
    }

    package var failed: Bool { !errors.isEmpty }

    /// Errors then warnings, one per line, prefixed so each reads on its own.
    package var issuesText: String {
        (errors.map { "Error: \($0)" } + warnings.map { "Warning: \($0)" }).joined(separator: "\n")
    }

    /// The status and the first error, which the window announces.
    package var announcement: String {
        errors.first.map { "\(status) \($0)" } ?? status
    }
}

/// Preferences › General › Edit raw configuration on Windows and Linux (#1670):
/// the same `SettingsDocument`, schema and validator as macOS, iOS, Android and
/// `speak config`, saved through the Preferences save path. Read-only keys
/// (this computer's consents and automation grants) are kept with a warning
/// instead of failing, as on the other platforms.
extension DesktopHostController {
    package static var rawConfigurationExportName: String { "JustSpeakToIt-settings.json" }
    /// Larger files are refused before they are read; the document is a few kilobytes.
    package static var rawConfigurationMaximumBytes: Int { 1_048_576 }

    package func rawConfiguration(
        _ action: DesktopRawConfigurationAction, text: String
    ) async -> DesktopRawConfigurationOutcome {
        do {
            switch action {
            case .load:
                return DesktopRawConfigurationOutcome(text: try Self.rawJSON(automationSettingsDocument()), status: "")
            case .defaults:
                return DesktopRawConfigurationOutcome(
                    text: try Self.rawJSON(rawConfigurationDefaults()), status: "Defaults loaded. Apply to save them."
                )
            case .validate:
                return try validateRawConfiguration(text).outcome
            case .apply:
                return try await applyRawConfiguration(text)
            case .importFile:
                return try importRawConfiguration(path: text)
            case .export:
                return exportRawConfiguration(text)
            }
        } catch {
            return DesktopRawConfigurationOutcome(
                status: "Nothing was saved.", errors: ["\(error)"]
            )
        }
    }

    /// Every editable setting at its default, keeping read-only values and
    /// which API keys are stored.
    func rawConfigurationDefaults() throws -> SettingsDocument {
        var document = try automationSettingsDocument()
        for field in SettingsSchema.fields(for: Self.settingsSchemaPlatform) where !field.isReadOnly {
            if let value = field.defaultValue { document.settings[field.key] = value }
        }
        return document
    }

    private struct RawValidation {
        var report: SettingsValidationReport?
        var outcome: DesktopRawConfigurationOutcome
    }

    private func validateRawConfiguration(_ text: String) throws -> RawValidation {
        switch SettingsDocument.parse(Data(text.utf8)) {
        case .failure(let error):
            return RawValidation(outcome: DesktopRawConfigurationOutcome(
                status: "The configuration is not valid.", errors: error.issues.map(\.description)
            ))
        case .success(let document):
            var context = SettingsValidationContext(
                currentValues: try automationSettingsValues(), ignoresReadOnlyChanges: true
            )
            context.platform = Self.settingsSchemaPlatform
            let report = SettingsValidator.validate(document, context: context)
            let count = report.changes.count
            let ready = count == 0 ? "Valid. Nothing to change." : "Valid. \(count) change(s) ready."
            let status = report.isValid ? ready : "The configuration is not valid. Nothing was saved."
            return RawValidation(report: report, outcome: DesktopRawConfigurationOutcome(
                status: status, errors: report.errors.map(\.description), warnings: report.warnings.map(\.description)
            ))
        }
    }

    private func applyRawConfiguration(_ text: String) async throws -> DesktopRawConfigurationOutcome {
        let validation = try validateRawConfiguration(text)
        guard let report = validation.report, report.isValid else { return validation.outcome }
        let warnings = report.warnings.map(\.description)
        guard !report.changes.isEmpty else {
            return DesktopRawConfigurationOutcome(status: "Nothing to change.", warnings: warnings)
        }
        guard settingsDocumentCanSave else {
            return DesktopRawConfigurationOutcome(
                status: "Nothing was saved.", errors: ["Finish dictation first."], warnings: warnings
            )
        }
        let previous = try configurationForNativeEditor()
        let candidate: DesktopConfiguration
        do {
            candidate = try Self.applyingAutomationChanges(report.changes, to: previous)
        } catch let error as DesktopConfigurationError {
            return DesktopRawConfigurationOutcome(status: "Nothing was saved.", errors: ["\(error)"])
        }
        let status = "Saved \(report.changes.count) change(s)."
        try await saveSettingsDocumentChanges(candidate, from: previous, status: status)
        return DesktopRawConfigurationOutcome(
            text: try Self.rawJSON(automationSettingsDocument()), status: status, warnings: warnings
        )
    }

    /// Loads a file into the editor and checks it. Nothing is saved until Apply.
    private func importRawConfiguration(path: String) throws -> DesktopRawConfigurationOutcome {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue
        guard let size, size <= Self.rawConfigurationMaximumBytes,
              let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            return DesktopRawConfigurationOutcome(
                status: "Could not read \(name).",
                errors: ["\(name) must be a UTF-8 JSON file no larger than 1 MB."]
            )
        }
        var outcome = try validateRawConfiguration(text).outcome
        outcome.text = text
        return outcome
    }

    /// Writes the editor's document, normalised, to the chosen path.
    private func exportRawConfiguration(_ payload: String) -> DesktopRawConfigurationOutcome {
        guard let newline = payload.firstIndex(of: "\n"), newline != payload.startIndex else {
            return DesktopRawConfigurationOutcome(status: "Could not export.", errors: ["Choose a file to export to."])
        }
        let url = URL(fileURLWithPath: String(payload[..<newline]))
        let text = payload[payload.index(after: newline)...]
        switch SettingsDocument.parse(Data(text.utf8)) {
        case .failure(let error):
            return DesktopRawConfigurationOutcome(
                status: "The configuration is not valid. Nothing was exported.",
                errors: error.issues.map(\.description)
            )
        case .success(let document):
            do {
                try document.encodedJSON().write(to: url, options: .atomic)
                return DesktopRawConfigurationOutcome(status: "Exported to \(url.lastPathComponent).")
            } catch {
                return DesktopRawConfigurationOutcome(
                    status: "Could not export.", errors: ["\(url.lastPathComponent): \(error.localizedDescription)"]
                )
            }
        }
    }

    private static func rawJSON(_ document: SettingsDocument) throws -> String {
        let data = try document.encodedJSON()
        guard let text = String(bytes: data, encoding: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        return text
    }
}
