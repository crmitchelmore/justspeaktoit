import Combine
import Foundation

/// Owns the persisted speech-insights aggregate behind the Mac and iOS
/// dashboards.
///
/// The aggregate is stored in the app's support directory and updated
/// incrementally: opening the dashboard only folds in sessions recorded since
/// the last visit, so it stays instant with 10k+ history items. Reconciliation
/// against the current history means deletions (manual or retention-driven)
/// drop out of the stats. Everything is computed locally and the aggregate is
/// never part of any sync payload.
@MainActor
public final class SpeechInsightsModel: ObservableObject {
    @Published public private(set) var summary: SpeechInsightsSummary?
    @Published public private(set) var isComputing = false

    private var aggregate: SpeechInsightsAggregate?
    private var refreshTask: Task<Void, Never>?
    private let storageURL: URL
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - storageURL: where the aggregate JSON is persisted.
    ///   - now: anchors "this week" and "this month"; tests pass a fixed date.
    public init(storageURL: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.storageURL = storageURL
        self.now = now
    }

    /// `<support>/Insights/speech-insights-aggregate.json`, creating the
    /// folder when needed.
    public nonisolated static func storageURL(
        inSupportDirectory support: URL,
        fileManager: FileManager = .default
    ) -> URL {
        let folder = support.appendingPathComponent("Insights", isDirectory: true)
        if !fileManager.fileExists(atPath: folder.path) {
            try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return folder.appendingPathComponent("speech-insights-aggregate.json", isDirectory: false)
    }

    /// Reconciles the aggregate with `records`. Serialized so rapid history
    /// changes cannot interleave; safe to call from `.task`.
    public func refresh(records: [SpeechSessionRecord]) {
        let previous = refreshTask
        refreshTask = Task { [weak self] in
            await previous?.value
            await self?.performRefresh(records: records)
        }
    }

    /// Awaits the most recently scheduled refresh (used by tests).
    public func waitForPendingRefresh() async {
        await refreshTask?.value
    }

    private func performRefresh(records: [SpeechSessionRecord]) async {
        if summary == nil {
            isComputing = true
        }
        let url = storageURL
        let cached = aggregate
        let reference = now()
        let (reconciled, newSummary) = await Task.detached(priority: .utility) {
            () -> (SpeechInsightsAggregate, SpeechInsightsSummary) in
            let base = cached ?? Self.loadAggregate(from: url) ?? SpeechInsightsAggregate()
            let reconciled = SpeechInsightsEngine.reconcile(base, with: records)
            if reconciled != base {
                Self.saveAggregate(reconciled, to: url)
            }
            return (reconciled, SpeechInsightsEngine.summary(for: reconciled, now: reference))
        }.value
        aggregate = reconciled
        summary = newSummary
        isComputing = false
    }

    private nonisolated static func loadAggregate(from url: URL) -> SpeechInsightsAggregate? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let aggregate = try? decoder.decode(SpeechInsightsAggregate.self, from: data),
              aggregate.schemaVersion == SpeechInsightsAggregate.currentSchemaVersion
        else { return nil }
        return aggregate
    }

    private nonisolated static func saveAggregate(_ aggregate: SpeechInsightsAggregate, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(aggregate) else { return }
        try? data.write(to: url, options: [.atomic])
    }
}
