import Foundation
import SpeakCore

/// Legacy History has no proven effective request snapshot. Never substitute current settings
/// or export its private diagnostic strings as public report fields.
enum HistoryIssueReporter {
    static func report(for item: HistoryItem, includeDiagnostics: Bool = true) -> IssueDiagnosticReport {
        IssueDiagnosticReport(failures: item.errors.map { error in
            RequestDiagnosticContext.Failure(stage: safeStage(for: error.phase), domain: .unknown)
        }, omittedSections: includeDiagnostics ? [] : Set(IssueDiagnosticReport.Section.allCases))
    }

    private static func safeStage(for phase: HistoryError.Phase) -> RequestDiagnosticContext.Stage {
        switch phase {
        case .recording, .storage: return .unknown
        case .transcription: return .request
        case .postProcessing: return .postProcessing
        case .output: return .output
        }
    }

    static func issueURL(for item: HistoryItem) -> URL? {
        report(for: item).issueURL
    }

    static func issueTitle(for item: HistoryItem) -> String {
        report(for: item).title
    }

    static func issueBody(for item: HistoryItem) -> String {
        report(for: item).body
    }
}
