import SpeakCore
import SwiftUI

@MainActor
struct HistoryIssueReportPreview: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller: HistoryIssueReportController

    init(report: IssueDiagnosticReport, reportWithoutDetails: IssueDiagnosticReport) {
        _controller = StateObject(wrappedValue: HistoryIssueReportController(
            report: report, reportWithoutDetails: reportWithoutDetails
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Review Public Issue Report")
                .font(.title2.bold())
            Text("Only the draft and JSON shown below are generated for sharing. "
                 + "Older History does not establish the effective request settings.")
            Toggle("Include diagnostics", isOn: Binding(
                get: { controller.includesDiagnostics },
                set: { controller.setIncludesDiagnostics($0) }
            ))
            .disabled(controller.isExporting)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(controller.report.title).font(.headline)
                    Text(controller.report.body)
                    Divider()
                    Text("JSON attachment").font(.headline)
                    Text(controller.report.jsonString).font(.system(.caption, design: .monospaced))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 240)
            Text("Save the JSON, open GitHub, describe the problem, and attach the saved file yourself. "
                 + "GitHub uploads a file immediately when you attach it, before you submit the issue. "
                 + "Saving or opening GitHub does not attach or submit anything.")
                .font(.callout)
            if let status = controller.status {
                Text(status.message).font(.callout)
            }
            HStack {
                Button("Cancel") {
                    controller.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save JSON…") { Task { await controller.exportJSON() } }
                    .disabled(controller.isExporting)
                Button("Copy Draft") { controller.copyDraft() }
                Button("Open GitHub") { controller.openGitHub() }
            }
        }
        .onDisappear { controller.cancel() }
        .padding(24)
        .frame(minWidth: 560, idealWidth: 680, minHeight: 520, idealHeight: 640)
    }
}
