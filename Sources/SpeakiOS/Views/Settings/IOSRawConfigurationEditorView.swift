#if os(iOS)
import SpeakCore
import SwiftUI
import UniformTypeIdentifiers

/// Settings → General → "Edit raw configuration": every iPhone setting as JSON,
/// validated against `SettingsSchema` and applied all or none (issue #1608).
/// API keys appear only as whether each is stored.
struct IOSRawConfigurationEditorView: View {
    @State private var text = ""
    @State private var errors: [SettingsIssue] = []
    @State private var warnings: [SettingsIssue] = []
    @State private var status: String?
    @State private var isImporting = false
    @State private var exportDocument: SettingsJSONFile?
    @State private var confirmingReset = false

    private var configuration: IOSSettingsConfiguration { IOSSettingsConfiguration() }

    var body: some View {
        Form {
            Section {
                TextEditor(text: $text)
                    .font(.footnote.monospaced())
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .frame(minHeight: 320)
                    .accessibilityLabel("Raw configuration JSON")
                    .accessibilityIdentifier("rawConfigurationEditor")
            } footer: {
                Text(
                    "Changes are checked before they are saved, and nothing is saved unless all of them are "
                        + "valid. API keys are never shown; \"apiKeys\" lists only whether each is stored."
                )
            }

            if status != nil || !errors.isEmpty || !warnings.isEmpty {
                issueSection
            }

            Section {
                Button("Validate") { _ = validate() }
                    .accessibilityIdentifier("rawConfigurationValidate")
                Button("Apply") { apply() }
                    .accessibilityIdentifier("rawConfigurationApply")
                Button("Import…") { isImporting = true }
                    .accessibilityIdentifier("rawConfigurationImport")
                Button("Export…") { export() }
                    .accessibilityIdentifier("rawConfigurationExport")
                Button("Reset to Defaults", role: .destructive) { confirmingReset = true }
                    .accessibilityIdentifier("rawConfigurationReset")
                    .accessibilityHint("Fills the editor with default values. Nothing is saved until you apply.")
            }
        }
        .navigationTitle("Raw configuration")
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .confirmationDialog("Load default values?", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Load Defaults") { resetToDefaults() }
        } message: {
            Text("The editor fills with defaults. Nothing is saved until you apply.")
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { result in
            importFile(result)
        }
        .fileExporter(
            isPresented: Binding(get: { exportDocument != nil }, set: { if !$0 { exportDocument = nil } }),
            document: exportDocument,
            contentType: .json,
            defaultFilename: "JustSpeakToIt-settings.json"
        ) { result in
            let status = switch result {
            case .success(let url): "Exported to \(url.lastPathComponent)."
            case .failure(let error): "Could not export: \(error.localizedDescription)"
            }
            report(errors: [], warnings: [], status: status)
        }
    }

    private var issueSection: some View {
        Section("Result") {
            if let status {
                Text(status)
                    .foregroundStyle(errors.isEmpty ? Color.secondary : Color.red)
                    .accessibilityIdentifier("rawConfigurationStatus")
            }
            ForEach(errors, id: \.self) { issue in
                Label(issue.description, systemImage: "xmark.octagon")
                    .foregroundStyle(.red)
                    .accessibilityLabel("Error: \(issue.description)")
            }
            ForEach(warnings, id: \.self) { issue in
                Label(issue.description, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Warning: \(issue.description)")
            }
        }
        .font(.callout)
        .accessibilityIdentifier("rawConfigurationIssues")
    }

    // MARK: Actions

    private func reload() async {
        show(await configuration.document())
    }

    private func show(_ document: SettingsDocument) {
        guard let data = try? document.encodedJSON(), let json = String(data: data, encoding: .utf8) else { return }
        text = json
    }

    private func resetToDefaults() {
        show(configuration.defaultsDocument())
        report(errors: [], warnings: [], status: "Defaults loaded. Apply to save them.")
    }

    private func validate() -> (SettingsDocument, SettingsValidationReport)? {
        switch SettingsDocument.parse(Data(text.utf8)) {
        case .failure(let error):
            report(errors: error.issues, warnings: [], status: "The configuration is not valid.")
            return nil
        case .success(let document):
            let result = configuration.validate(document: document)
            let summary = if !result.isValid {
                "The configuration is not valid. Nothing was saved."
            } else if result.changes.isEmpty {
                "Valid. Nothing to change."
            } else {
                "Valid. \(result.changes.count) change(s) ready."
            }
            report(errors: result.errors, warnings: result.warnings, status: summary)
            return (document, result)
        }
    }

    private func apply() {
        guard let (document, result) = validate(), result.isValid else { return }
        do {
            try configuration.apply(
                result, foreign: IOSSettingsConfiguration.foreignValues(of: document, report: result))
            report(
                errors: [], warnings: result.warnings,
                status: result.changes.isEmpty ? "Nothing to change." : "Saved \(result.changes.count) change(s).")
            Task { await reload() }
        } catch let error as IOSSettingsConfiguration.ApplyError {
            report(errors: error.issues, warnings: [], status: "Nothing was saved.")
        } catch {
            report(errors: [], warnings: [], status: error.localizedDescription)
        }
    }

    private func importFile(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error):
            report(errors: [], warnings: [], status: "Could not import: \(error.localizedDescription)")
        case .success(let url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                text = try String(contentsOf: url, encoding: .utf8)
                _ = validate()
            } catch {
                report(errors: [], warnings: [], status: "Could not read \(url.lastPathComponent).")
            }
        }
    }

    private func export() {
        guard case .success(let document) = SettingsDocument.parse(Data(text.utf8)),
              let data = try? document.encodedJSON()
        else {
            _ = validate()
            return
        }
        exportDocument = SettingsJSONFile(data: data)
    }

    /// Shows the outcome and announces it, so VoiceOver users hear errors.
    private func report(errors: [SettingsIssue], warnings: [SettingsIssue], status: String) {
        self.errors = errors
        self.warnings = warnings
        self.status = status
        let firstIssue = errors.first.map { " \($0.description)" } ?? ""
        AccessibilityNotification.Announcement(status + firstIssue).post()
    }
}

/// A settings document as a JSON file for `fileExporter`.
struct SettingsJSONFile: FileDocument {
    static let readableContentTypes: [UTType] = [.json]

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// General's entry point to the raw configuration editor.
struct IOSRawConfigurationSection: View {
    var body: some View {
        SearchableSettingsSection("Edit raw configuration") {
            NavigationLink {
                IOSRawConfigurationEditorView()
            } label: {
                Label("Raw configuration", systemImage: "curlybraces")
            }
            .accessibilityIdentifier("rawConfigurationOpen")

            SettingsFootnote("View, validate, import or export every setting as JSON, or reset to defaults.")
        }
    }
}
#endif
