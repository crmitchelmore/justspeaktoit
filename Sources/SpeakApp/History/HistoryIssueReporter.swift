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
        let times = item.phaseTimestamps
        let failed = Set(item.errors.map(\.phase))
        func event(
            _ stage: RequestDiagnosticContext.Stage, _ phase: HistoryError.Phase, from start: Date?, to end: Date?
        ) -> RequestDiagnosticContext.Event? {
            guard let start, let end, end >= start else { return nil }
            return .init(stage: stage, outcome: failed.contains(phase) ? .failed : .succeeded,
                         elapsedMilliseconds: Int(end.timeIntervalSince(start) * 1_000))
        }
        // Live transcription streams during recording; its recorded interval is only finalisation.
        let isLive = item.modelUsages.contains { $0.phase == .transcriptionLive }
        let processingEnded = times.postProcessingEnded ?? times.transcriptionEnded
        return [
            event(isLive ? .finalization : .request, .transcription,
                  from: times.transcriptionStarted, to: times.transcriptionEnded),
            event(.postProcessing, .postProcessing, from: times.postProcessingStarted, to: times.postProcessingEnded),
            event(.output, .output, from: processingEnded, to: times.outputDelivered)
        ].compactMap { $0 }
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
