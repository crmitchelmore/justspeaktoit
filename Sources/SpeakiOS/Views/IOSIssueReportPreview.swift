#if os(iOS)
import Foundation
import SpeakCore
import SwiftUI
import UniformTypeIdentifiers

/// Export-only memory document. External JSON is never imported as a trusted
/// report, and no app-owned temporary file or user-specific name is needed.
struct IOSIssueReportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data

    init(report: IssueDiagnosticReport) { self.data = report.jsonData }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.fileReadUnsupportedScheme)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        makeFileWrapper()
    }

    func makeFileWrapper() -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

@MainActor
struct IOSIssueReportPreview: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller: IOSIssueReportController
    @State private var showingExporter = false

    init(controller: IOSIssueReportController) {
        self._controller = StateObject(wrappedValue: controller)
    }

    var body: some View {
        // Capture this exact export token in the system completion closures;
        // an older chooser cannot settle a later document or preview.
        let export = controller.pendingExport
        NavigationStack {
            Form {
                Section {
                    Text("Review the draft before sharing. "
                         + "Request-time context was not recorded for these iOS details.")
                    Toggle("Include diagnostics", isOn: Binding(
                        get: { controller.includesDiagnostics },
                        set: { controller.setIncludesDiagnostics($0) }
                    ))
                    .frame(minHeight: 44)
                    .disabled(controller.isExporting || controller.isOpening)
                    .accessibilityIdentifier("issueReportIncludeDiagnostics")
                }
                Section("Public issue draft") {
                    Text(controller.report.title).font(.headline)
                    Text(controller.report.body).textSelection(.enabled)
                }
                Section("JSON attachment") {
                    Text(controller.report.jsonString)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                Section {
                    Button {
                        if controller.beginExport() != nil { showingExporter = true }
                    } label: {
                        Text("Save JSON…").frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("issueReportSaveJSON")
                    Button { controller.copyDraft() } label: {
                        Text("Copy Draft").frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("issueReportCopyDraft")
                    Button { Task { await controller.openGitHub() } } label: {
                        Text("Open GitHub").frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("issueReportOpenGitHub")
                } footer: {
                    Text("Save the JSON, open GitHub, describe the problem, and attach the saved file yourself. "
                         + "GitHub uploads a file as soon as you attach it. "
                         + "Saving or opening does not attach or submit.")
                }
                .disabled(controller.isExporting || controller.isOpening)
                if let status = controller.status {
                    Section { Text(status.message).accessibilityIdentifier("issueReportStatus") }
                }
            }
            .environment(\.defaultMinListRowHeight, 44)
            .navigationTitle("Review Issue Report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { controller.cancel(); dismiss() }
                        .disabled(controller.isExporting)
                        .accessibilityIdentifier("issueReportCancel")
                }
            }
            .interactiveDismissDisabled(controller.isExporting)
            .fileExporter(
                isPresented: $showingExporter, document: export?.document, contentTypes: [.json],
                defaultFilename: IssueDiagnosticReport.attachmentFilename,
                onCompletion: { result in
                    guard let identifier = export?.id else { return }
                    switch result {
                    case .success: controller.completeExport(identifier, outcome: .saved)
                    case .failure: controller.completeExport(identifier, outcome: .failed)
                    }
                },
                onCancellation: {
                    if let identifier = export?.id { controller.completeExport(identifier, outcome: .cancelled) }
                }
            )
        }
        .onDisappear {
            // The system picker may cover this view. Its already-admitted
            // document remains frozen; dismissal is blocked while it is open.
            if !controller.isExporting { controller.cancel() }
        }
    }
}
#endif
