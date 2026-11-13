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
        // A successful legacy entry has no request context, so its catalogue-safe
        // recorded models are what make a wrong-model report actionable.
        let recordedModels = item.errors.isEmpty && item.diagnosticContext?.requestContext == nil
            ? item.modelsUsed.prefix(8).map { RequestDiagnosticContext.ModelSelection.project($0) } : []
        return IssueDiagnosticReport(
            context: item.diagnosticContext?.requestContext, recordedModels: recordedModels, failures: failures,
            events: timeline(for: item),
            omittedSections: includeDiagnostics ? [] : Set(IssueDiagnosticReport.Section.allCases),
            observedHandoff: item.diagnosticContext?.observedHandoff,
            postProcessingObservation: item.diagnosticContext?.postProcessingObservation
        )
    }

    /// Relative phase durations only, so a slow successful request can be reported
    /// without exporting absolute timestamps.
    static func timeline(for item: HistoryItem) -> [RequestDiagnosticContext.Event] {
        HistoryDetailFormatting.diagnosticTimeline(
            item.phaseTimestamps, failedPhases: Set(item.errors.map(\.phase)),
            isLive: item.modelUsages.contains { $0.phase == .transcriptionLive }
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
