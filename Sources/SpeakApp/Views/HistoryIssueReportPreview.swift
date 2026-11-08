import SpeakCore
import SwiftUI

/// Presented once from `HistoryView`, never from a lazy row. Every phase renders
/// a sized view with Cancel bound to Escape, so the sheet can always be closed.
@MainActor
struct HistoryIssueReportPreview: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var loader: HistoryIssueReportLoader

    init(item: HistoryItem) {
        _loader = StateObject(wrappedValue: HistoryIssueReportLoader(item: item))
    }

    var body: some View {
        Group {
            switch loader.phase {
            case .loading:
                placeholder {
                    ProgressView("Preparing issue report…")
                }
            case .timedOut:
                placeholder {
                    Text("The issue report took too long to prepare. Close this window and try again.")
                }
            case .ready(let controller):
                HistoryIssueReportContent(controller: controller, close: close)
            }
        }
        .padding(24)
        .frame(minWidth: 560, idealWidth: 680, minHeight: 520, idealHeight: 640)
        .onExitCommand(perform: close)
        .onAppear { loader.start() }
        .onDisappear { loader.cancel() }
    }

    private func close() {
        loader.cancel()
        dismiss()
    }

    private func placeholder<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Review Public Issue Report")
                .font(.title2.bold())
            Spacer()
            content().frame(maxWidth: .infinity)
            Spacer()
            HStack {
                Button("Cancel", action: close)
                    .keyboardShortcut(.cancelAction)
                Spacer()
            }
        }
    }
}

@MainActor
private struct HistoryIssueReportContent: View {
    @ObservedObject var controller: HistoryIssueReportController
    let close: () -> Void

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
                Button("Cancel", action: close)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save JSON…") { Task { await controller.exportJSON() } }
                    .disabled(controller.isExporting)
                Button("Copy Draft") { controller.copyDraft() }
                Button("Open GitHub") { controller.openGitHub() }
            }
        }
    }
}
