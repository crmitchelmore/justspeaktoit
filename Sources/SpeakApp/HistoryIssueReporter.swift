import Foundation
import SpeakCore

/// Use only the request-owned allowlisted snapshot when recorded. Legacy History fields
/// never establish effective settings or authorize exporting private diagnostic strings.
enum HistoryIssueReporter {
    static func report(for item: HistoryItem, includeDiagnostics: Bool = true) -> IssueDiagnosticReport {
        let legacyPhases = item.errors.map { error in
            RequestDiagnosticContext.Failure(stage: safeStage(for: error.phase), domain: .unknown)
        }
        let failures = item.diagnosticContext?.requestFailure.map { [$0] + legacyPhases } ?? legacyPhases
        return IssueDiagnosticReport(
            context: item.diagnosticContext?.requestContext, failures: failures,
            omittedSections: includeDiagnostics ? [] : Set(IssueDiagnosticReport.Section.allCases),
            observedHandoff: item.diagnosticContext?.observedHandoff
        )
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
