import AppKit
import Combine
import SpeakCore
import UniformTypeIdentifiers

/// One immutable report owns every preview/action. No action runs during construction.
@MainActor
final class HistoryIssueReportController: ObservableObject {
    struct Dependencies {
        var chooseDestination: @MainActor (String) async -> URL?
        var write: @MainActor (Data, URL) throws -> Void
        var copy: @MainActor (String) -> Void
        var open: @MainActor (URL) -> Bool

        static var live: Self {
            Self(
                chooseDestination: { filename in
                    let panel = NSSavePanel()
                    panel.allowedContentTypes = [.json]
                    panel.nameFieldStringValue = filename
                    guard await panel.begin() == .OK else { return nil }
                    return panel.url
                },
                write: { data, url in try data.write(to: url, options: .atomic) },
                copy: { CopyFeedback.copy($0) },
                open: { NSWorkspace.shared.open($0) }
            )
        }
    }

    enum Status: Equatable {
        case copied, exported, opened, exportFailed, browserFailed, browserUnavailable

        var message: String {
            switch self {
            case .copied: return "Draft copied."
            case .exported: return "Diagnostics saved. Attach the JSON yourself in GitHub."
            case .opened: return "GitHub opened. Nothing has been attached or submitted."
            case .exportFailed: return "Could not save diagnostics. Try another destination."
            case .browserFailed: return "Could not open GitHub. You can copy the draft instead."
            case .browserUnavailable: return "This draft cannot fit in a browser link. Copy it into a new GitHub issue."
            }
        }
    }

    @Published private(set) var report: IssueDiagnosticReport
    @Published private(set) var includesDiagnostics = true
    private let fullReport: IssueDiagnosticReport
    private let reportWithoutDetails: IssueDiagnosticReport
    @Published private(set) var status: Status?
    @Published private(set) var isExporting = false
    private let dependencies: Dependencies
    private var isClosed = false

    convenience init(report: IssueDiagnosticReport, reportWithoutDetails: IssueDiagnosticReport) {
        self.init(report: report, reportWithoutDetails: reportWithoutDetails, dependencies: .live)
    }

    init(report: IssueDiagnosticReport, reportWithoutDetails: IssueDiagnosticReport, dependencies: Dependencies) {
        self.report = report
        self.fullReport = report
        self.reportWithoutDetails = reportWithoutDetails
        self.dependencies = dependencies
    }

    func setIncludesDiagnostics(_ included: Bool) {
        guard !isClosed, !isExporting else { return }
        includesDiagnostics = included
        report = included ? fullReport : reportWithoutDetails
        status = nil
    }

    func cancel() {
        isClosed = true
    }

    func copyDraft() {
        guard !isClosed else { return }
        dependencies.copy(report.body)
        status = .copied
    }

    func openGitHub() {
        guard !isClosed else { return }
        guard let url = report.issueURL else {
            status = .browserUnavailable
            return
        }
        status = dependencies.open(url) ? .opened : .browserFailed
    }

    func exportJSON() async {
        guard !isClosed, !isExporting, !Task.isCancelled else { return }
        isExporting = true
        defer { isExporting = false }
        guard let destination = await dependencies.chooseDestination(IssueDiagnosticReport.attachmentFilename),
              !isClosed, !Task.isCancelled else { return }
        do {
            try dependencies.write(report.jsonData, destination)
            status = .exported
        } catch {
            // Never disclose the selected path or an arbitrary filesystem error.
            status = .exportFailed
        }
    }
}
