import AppKit
import SpeakCore
import SwiftUI
import UniformTypeIdentifiers

/// Settings → General → Advanced → "Edit raw configuration": the whole macOS
/// configuration as JSON, validated against `SettingsSchema` and applied all or
/// none. API keys appear only as whether they are stored.
struct RawConfigurationEditorView: View {
  @EnvironmentObject private var environment: AppEnvironment
  @Environment(\.dismiss) private var dismiss

  @State private var text = ""
  @State private var errors: [SettingsIssue] = []
  @State private var warnings: [SettingsIssue] = []
  @State private var status: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Raw configuration")
        .font(.title2.weight(.semibold))
        .accessibilityAddTraits(.isHeader)
      Text(
        "Every setting as JSON. Changes are checked before they are saved, and nothing is saved unless all of "
          + "them are valid. API keys are never shown; \"apiKeys\" lists only whether each is stored."
      )
      .font(.callout)
      .foregroundStyle(.secondary)

      TextEditor(text: $text)
        .font(.body.monospaced())
        .frame(minHeight: 320)
        .border(Color.secondary.opacity(0.3))
        .accessibilityLabel("Raw configuration JSON")
        .accessibilityIdentifier("rawConfigurationEditor")

      issueList

      HStack {
        Button("Reset to Defaults") { resetToDefaults() }
          .accessibilityIdentifier("rawConfigurationReset")
          .speakTooltip("Fill the editor with default values. Nothing is saved until you apply.")
        Button("Import…") { importFile() }
          .accessibilityIdentifier("rawConfigurationImport")
        Button("Export…") { exportFile() }
          .accessibilityIdentifier("rawConfigurationExport")
        Spacer()
        Button("Close") { dismiss() }
          .keyboardShortcut(.cancelAction)
          .accessibilityIdentifier("rawConfigurationClose")
        Button("Validate") { _ = validate() }
          .accessibilityIdentifier("rawConfigurationValidate")
        Button("Apply") { apply() }
          .keyboardShortcut(.defaultAction)
          .accessibilityIdentifier("rawConfigurationApply")
      }
    }
    .padding(20)
    .frame(minWidth: 640, minHeight: 520)
    .task { await reload() }
  }

  @ViewBuilder private var issueList: some View {
    if let status {
      Text(status)
        .font(.callout)
        .foregroundStyle(errors.isEmpty ? Color.secondary : Color.red)
        .accessibilityIdentifier("rawConfigurationStatus")
    }
    if !errors.isEmpty || !warnings.isEmpty {
      ScrollView {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(errors, id: \.self) { issue in
            Label(issue.description, systemImage: "xmark.octagon")
              .foregroundStyle(.red)
          }
          ForEach(warnings, id: \.self) { issue in
            Label(issue.description, systemImage: "exclamationmark.triangle")
              .foregroundStyle(.secondary)
          }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: 120)
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Configuration issues")
      .accessibilityIdentifier("rawConfigurationIssues")
    }
  }

  private var configuration: AppSettingsConfiguration {
    AppSettingsConfiguration(settings: environment.settings) { [secureStorage = environment.secureStorage] in
      await secureStorage.hasSecret(identifier: $0)
    }
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

  /// Parses and validates the editor's text, reporting every issue.
  private func validate() -> (SettingsDocument, SettingsValidationReport)? {
    switch SettingsDocument.parse(Data(text.utf8)) {
    case .failure(let error):
      report(errors: error.issues, warnings: [], status: "The configuration is not valid.")
      return nil
    case .success(let document):
      let result = configuration.validate(document: document)
      let summary = result.isValid
        ? (result.changes.isEmpty ? "Valid. Nothing to change." : "Valid. \(result.changes.count) change(s) ready.")
        : "The configuration is not valid. Nothing was saved."
      report(errors: result.errors, warnings: result.warnings, status: summary)
      return (document, result)
    }
  }

  private func apply() {
    guard let (document, result) = validate(), result.isValid else { return }
    let configuration = self.configuration
    do {
      try configuration.apply(result, foreign: AppSettingsConfiguration.foreignValues(of: document, report: result))
      report(
        errors: [], warnings: result.warnings,
        status: result.changes.isEmpty ? "Nothing to change." : "Saved \(result.changes.count) change(s).")
      Task { await reload() }
    } catch let error as AppSettingsConfiguration.ApplyError {
      report(errors: error.issues, warnings: [], status: "Nothing was saved.")
    } catch {
      report(errors: [], warnings: [], status: error.localizedDescription)
    }
  }

  private func importFile() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json]
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      text = try String(contentsOf: url, encoding: .utf8)
      _ = validate()
    } catch {
      report(errors: [], warnings: [], status: "Could not read \(url.lastPathComponent).")
    }
  }

  private func exportFile() {
    guard case .success(let document) = SettingsDocument.parse(Data(text.utf8)) else {
      _ = validate()
      return
    }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.json]
    panel.nameFieldStringValue = "JustSpeakToIt-settings.json"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      try document.encodedJSON().write(to: url, options: .atomic)
      report(errors: [], warnings: [], status: "Exported to \(url.lastPathComponent).")
    } catch {
      report(errors: [], warnings: [], status: "Could not export: \(error.localizedDescription)")
    }
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

/// The Advanced card's entry point to the raw configuration editor.
struct RawConfigurationButton: View {
  @EnvironmentObject private var environment: AppEnvironment
  @State private var isPresented = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Button("Edit raw configuration…") { isPresented = true }
        .accessibilityIdentifier("rawConfigurationOpen")
        .speakTooltip("View, validate, import or export every setting as JSON.")
      Text("Every setting as validated JSON, with import, export and reset to defaults.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .settingsSearchAnchor(title: "Edit raw configuration")
    .sheet(isPresented: $isPresented) {
      RawConfigurationEditorView()
        .environmentObject(environment)
    }
  }
}
