#if os(iOS)
import Combine
import Foundation
import SpeakCore
import UIKit

/// Only error presence and a canonical recorded model are projected. Neither
/// establishes effective settings or a provider handoff for this request.
enum IOSIssueReporter {
    static func snapshot(for item: iOSHistoryItem) -> IOSIssueReportSnapshot {
        IOSIssueReportSnapshot(hasFailure: item.errorMessage != nil, recordedModels: [.project(item.model)])
    }

    static func failedRequest() -> IOSIssueReportSnapshot {
        IOSIssueReportSnapshot(hasFailure: true)
    }
}

struct IOSIssueReportSnapshot {
    let full: IssueDiagnosticReport
    let withoutDetails: IssueDiagnosticReport

    init(hasFailure: Bool, recordedModels: [RequestDiagnosticContext.ModelSelection] = []) {
        let failures: [RequestDiagnosticContext.Failure] = hasFailure ? [.init(domain: .unknown)] : []
        self.full = IssueDiagnosticReport(recordedModels: recordedModels, failures: failures)
        self.withoutDetails = IssueDiagnosticReport(
            recordedModels: recordedModels, failures: failures,
            omittedSections: Set(IssueDiagnosticReport.Section.allCases)
        )
    }
}

/// Presentation-local ownership only. No persistent History/session identity
/// or source row is retained by this controller or sent in its report.
@MainActor
final class IOSIssueReportController: ObservableObject, Identifiable {
    struct Dependencies {
        var copy: @MainActor (String) -> Bool
        var open: @MainActor (URL) async -> Bool

        static var live: Self {
            Self(copy: { TranscriptClipboard.shared.copy($0) }, open: { await UIApplication.shared.open($0) })
        }
    }

    struct Export: Identifiable {
        let id = UUID()
        let document: IOSIssueReportDocument
    }

    enum ExportOutcome { case saved, cancelled, failed }
    enum Status: Equatable {
        case copied, copyFailed, opened, browserFailed, browserUnavailable, exported, exportCancelled, exportFailed

        var message: String {
            switch self {
            case .copied: return "Draft copied."
            case .copyFailed: return "Could not copy the draft. Try again."
            case .opened: return "GitHub opened. Nothing has been attached or submitted."
            case .browserFailed: return "Could not open GitHub. You can copy the draft instead."
            case .browserUnavailable: return "This draft cannot fit in a browser link. Copy it into a new GitHub issue."
            case .exported: return "Diagnostics saved. Attach the JSON yourself in GitHub."
            case .exportCancelled: return "Export cancelled."
            case .exportFailed: return "Could not save diagnostics. Try another destination."
            }
        }
    }

    let id = UUID()
    @Published private(set) var report: IssueDiagnosticReport
    @Published private(set) var includesDiagnostics = true
    @Published private(set) var pendingExport: Export?
    @Published private(set) var isOpening = false
    @Published private(set) var status: Status?
    private let snapshot: IOSIssueReportSnapshot
    private let dependencies: Dependencies
    private var isClosed = false
    var isExporting: Bool { pendingExport != nil }

    convenience init(snapshot: IOSIssueReportSnapshot) {
        self.init(snapshot: snapshot, dependencies: .live)
    }

    init(snapshot: IOSIssueReportSnapshot, dependencies: Dependencies) {
        self.snapshot = snapshot
        self.report = snapshot.full
        self.dependencies = dependencies
    }

    func setIncludesDiagnostics(_ included: Bool) {
        guard !isClosed, !isExporting, !isOpening else { return }
        includesDiagnostics = included
        report = included ? snapshot.full : snapshot.withoutDetails
        status = nil
    }

    func cancel() {
        isClosed = true
        pendingExport = nil
        // A system-admitted export or browser open cannot be retracted here.
        // Never delete the user's file or claim that cancellation did so.
    }

    func copyDraft() {
        guard !isClosed, !isExporting, !isOpening else { return }
        status = dependencies.copy(report.body) ? .copied : .copyFailed
    }

    func openGitHub() async {
        guard !isClosed, !isExporting, !isOpening, !Task.isCancelled else { return }
        guard let url = report.issueURL else { status = .browserUnavailable; return }
        isOpening = true
        defer { isOpening = false }
        let opened = await dependencies.open(url)
        guard !isClosed, !Task.isCancelled else { return }
        status = opened ? .opened : .browserFailed
    }

    @discardableResult
    func beginExport() -> Export? {
        guard !isClosed, !isExporting, !isOpening, !Task.isCancelled else { return nil }
        let export = Export(document: IOSIssueReportDocument(report: report))
        pendingExport = export
        status = nil
        return export
    }

    func completeExport(_ identifier: UUID, outcome: ExportOutcome) {
        guard !isClosed, pendingExport?.id == identifier else { return }
        pendingExport = nil
        switch outcome {
        case .saved: status = .exported
        case .cancelled: status = .exportCancelled
        case .failed: status = .exportFailed
        }
    }
}
#endif
