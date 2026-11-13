import Foundation

// Session-detail formatting shared by every History surface, so a new model
// phase, trigger or timing appears the same way on Mac and iPhone.

extension ApplicationModelUsagePhase {
    /// The short label History shows next to the models a phase used.
    public var historyLabel: String {
        switch self {
        case .transcriptionLive: return "Live"
        case .transcriptionBatch: return "Batch"
        case .transcriptionLocal: return "Local"
        case .postProcessing: return "Post-processing"
        }
    }

    /// Pipeline order. Every phase has a distinct rank so grouped summaries
    /// never reorder themselves between renders.
    public var historyOrder: Int {
        switch self {
        case .transcriptionLive: return 0
        case .transcriptionBatch: return 1
        case .transcriptionLocal: return 2
        case .postProcessing: return 3
        }
    }
}

/// The models one pipeline phase used, with friendly names.
public struct HistoryModelsByPhase: Equatable, Sendable {
    public let phase: ApplicationModelUsagePhase
    public let phaseLabel: String
    public let models: String

    public init(phase: ApplicationModelUsagePhase, phaseLabel: String, models: String) {
        self.phase = phase
        self.phaseLabel = phaseLabel
        self.models = models
    }
}

extension ApplicationHistoryTrigger {
    /// The gesture as people read it, such as "Double tap" or "Button".
    public var gestureLabel: String {
        switch self.gesture {
        case .singleTap: "Single tap"
        case .doubleTap: "Double tap"
        case .hold: "Hold"
        case .uiButton: "Button"
        case .automation: "Automation"
        }
    }

    /// Whether ``hotKeyDescription`` names a hot key rather than a button or source such as Compare Models.
    public var isHotKeyGesture: Bool {
        switch self.gesture {
        case .singleTap, .doubleTap, .hold: true
        case .uiButton, .automation: false
        }
    }

    /// One line such as "Double tap · Right Option" or "Automation · Shortcut".
    public var historySummary: String {
        let description = self.hotKeyDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return description.isEmpty ? self.gestureLabel : "\(self.gestureLabel) · \(description)"
    }
}

public enum HistoryDetailFormatting {
    /// Model usages grouped by phase in pipeline order, with friendly names.
    public static func modelsByPhase(_ usages: [ApplicationModelUsage]) -> [HistoryModelsByPhase] {
        Dictionary(grouping: usages, by: \.phase)
            .sorted { $0.key.historyOrder < $1.key.historyOrder }
            .map { phase, usages in
                var seen = Set<String>()
                let names = usages.map(\.modelIdentifier).filter { seen.insert($0).inserted }
                    .map { ModelCatalog.friendlyName(for: $0) }
                return HistoryModelsByPhase(
                    phase: phase, phaseLabel: phase.historyLabel, models: names.joined(separator: ", ")
                )
            }
    }

    /// Whole-cent amounts use the currency's usual digits; a non-zero amount under one cent keeps up to
    /// four decimal places, and anything smaller reads "< $0.0001", so cheap requests never show "$0.00".
    public static func formatCurrency(_ value: Decimal, currency: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency.isEmpty ? "USD" : currency
        let smallest = Decimal(sign: .plus, exponent: -4, significand: 1)
        guard value > 0, value < Decimal(sign: .plus, exponent: -2, significand: 1) else {
            return formatter.string(from: NSDecimalNumber(decimal: value)) ?? "$0.00"
        }
        formatter.maximumFractionDigits = 4
        if value < smallest {
            return "< " + (formatter.string(from: NSDecimalNumber(decimal: smallest)) ?? "$0.0001")
        }
        return formatter.string(from: NSDecimalNumber(decimal: value)) ?? "$0.00"
    }

    /// "850 ms" below a second, otherwise "2.4 s" or "1m 05s"; nil when unknown.
    public static func formatLatency(_ interval: TimeInterval) -> String? {
        guard interval.isFinite, interval >= 0 else { return nil }
        if interval < 1 { return "\(Int((interval * 1_000).rounded())) ms" }
        if interval < 60 { return String(format: "%.1f s", interval) }
        let seconds = Int(interval.rounded())
        return String(format: "%dm %02ds", seconds / 60, seconds % 60)
    }

    /// Relative phase durations only, so a slow successful request can be
    /// reported without exporting absolute timestamps.
    public static func diagnosticTimeline(
        _ times: ApplicationPhaseTimestamps?, failedPhases: Set<ApplicationHistoryError.Phase> = [],
        isLive: Bool
    ) -> [RequestDiagnosticContext.Event] {
        guard let times else { return [] }
        func event(
            _ stage: RequestDiagnosticContext.Stage, _ phase: ApplicationHistoryError.Phase,
            from start: Date?, to end: Date?
        ) -> RequestDiagnosticContext.Event? {
            guard let start, let end, end >= start else { return nil }
            return .init(stage: stage, outcome: failedPhases.contains(phase) ? .failed : .succeeded,
                         elapsedMilliseconds: Int(end.timeIntervalSince(start) * 1_000))
        }
        // Live transcription streams during recording; its recorded interval is only finalisation.
        let processingEnded = times.postProcessingEnded ?? times.transcriptionEnded
        return [
            event(isLive ? .finalization : .request, .transcription,
                  from: times.transcriptionStarted, to: times.transcriptionEnded),
            event(.postProcessing, .postProcessing, from: times.postProcessingStarted, to: times.postProcessingEnded),
            event(.output, .output, from: processingEnded, to: times.outputDelivered)
        ].compactMap { $0 }
    }
}

/// The "Session details" rows History shows for one entry. Values are display
/// strings only; no transcript text enters the summary.
public struct HistoryDetailSummary: Equatable, Sendable {
    public struct Row: Equatable, Identifiable, Sendable {
        /// Stable identifier, also used as an automation-ID suffix.
        public let id: String
        public let title: String
        public let value: String

        public init(id: String, title: String, value: String) {
            self.id = id
            self.title = title
            self.value = value
        }
    }

    public let rows: [Row]

    public init(record: HistoryRecord) {
        var rows: [Row] = []
        if let trigger = record.trigger {
            rows.append(Row(id: "trigger", title: "Trigger", value: trigger.historySummary))
        }
        rows += Self.modelRows(record)
        let duration = record.recordingDuration
        if let recording = HistoryDetailFormatting.formatLatency(duration), duration > 0 {
            rows.append(Row(id: "recording", title: "Recording", value: recording))
        }
        rows += Self.timingRows(record.phaseTimestamps)
        if let cost = record.cost {
            rows.append(Row(
                id: "cost", title: "Cost",
                value: HistoryDetailFormatting.formatCurrency(cost.total, currency: cost.currency)
            ))
        }
        self.rows = rows
    }

    private static func modelRows(_ record: HistoryRecord) -> [Row] {
        if !record.modelUsages.isEmpty {
            return HistoryDetailFormatting.modelsByPhase(record.modelUsages).map {
                Row(id: "model-\($0.phase.rawValue)", title: "\($0.phaseLabel) model", value: $0.models)
            }
        }
        let identifiers = record.model.map { [$0] } ?? record.modelsUsed
        let names = identifiers.filter { !$0.isEmpty }.map { ModelCatalog.friendlyName(for: $0) }
        guard !names.isEmpty else { return [] }
        return [Row(id: "model", title: names.count == 1 ? "Model" : "Models", value: names.joined(separator: ", "))]
    }

    private static func timingRows(_ times: ApplicationPhaseTimestamps?) -> [Row] {
        guard let times else { return [] }
        var rows: [Row] = []
        func interval(_ start: Date?, _ end: Date?) -> String? {
            guard let start, let end else { return nil }
            return HistoryDetailFormatting.formatLatency(end.timeIntervalSince(start))
        }
        if let value = interval(times.recordingEnded ?? times.transcriptionStarted, times.transcriptionEnded) {
            rows.append(Row(id: "transcript-latency", title: "Transcript ready", value: "\(value) after stop"))
        }
        if let value = interval(times.postProcessingStarted, times.postProcessingEnded) {
            rows.append(Row(id: "post-processing-latency", title: "Post-processing", value: value))
        }
        let end = times.outputDelivered ?? times.postProcessingEnded ?? times.transcriptionEnded
        if let value = interval(times.recordingStarted, end) {
            rows.append(Row(id: "total", title: "Total", value: value))
        }
        return rows
    }
}
