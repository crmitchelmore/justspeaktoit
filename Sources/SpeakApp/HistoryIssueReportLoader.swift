import Combine
import Foundation
import SpeakCore

/// Builds both report variants off the main actor so opening the review sheet
/// never blocks the window. The sheet always has visible content: a progress
/// state, the ready preview or a fixed timeout message, each with Cancel.
@MainActor
final class HistoryIssueReportLoader: ObservableObject {
    struct Reports: Sendable {
        let full: IssueDiagnosticReport
        let withoutDetails: IssueDiagnosticReport
    }

    enum Phase {
        case loading
        case ready(HistoryIssueReportController)
        case timedOut
    }

    typealias Generate = @Sendable (HistoryItem) -> Reports

    nonisolated static let liveGenerate: Generate = { item in
        Reports(
            full: HistoryIssueReporter.report(for: item),
            withoutDetails: HistoryIssueReporter.report(for: item, includeDiagnostics: false)
        )
    }

    nonisolated static let defaultTimeout: Duration = .seconds(5)

    @Published private(set) var phase: Phase = .loading
    private let item: HistoryItem
    private let timeout: Duration
    private let generate: Generate
    private let makeController: @MainActor (Reports) -> HistoryIssueReportController
    private var work: Task<Void, Never>?
    private var deadline: Task<Void, Never>?

    convenience init(item: HistoryItem) {
        self.init(item: item, timeout: Self.defaultTimeout, generate: Self.liveGenerate) {
            HistoryIssueReportController(report: $0.full, reportWithoutDetails: $0.withoutDetails)
        }
    }

    init(
        item: HistoryItem, timeout: Duration, generate: @escaping Generate,
        makeController: @escaping @MainActor (Reports) -> HistoryIssueReportController
    ) {
        self.item = item
        self.timeout = timeout
        self.generate = generate
        self.makeController = makeController
    }

    var isLoading: Bool {
        if case .loading = phase { return true }
        return false
    }

    /// Idempotent. Returns immediately; generation runs on a detached task.
    func start() {
        guard isLoading, work == nil else { return }
        let item = item
        let generate = generate
        work = Task { [weak self] in
            let reports = await Task.detached(priority: .userInitiated) { generate(item) }.value
            guard let self, !Task.isCancelled, self.isLoading else { return }
            self.deadline?.cancel()
            self.phase = .ready(self.makeController(reports))
        }
        let timeout = timeout
        deadline = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard let self, !Task.isCancelled, self.isLoading else { return }
            self.work?.cancel()
            self.phase = .timedOut
        }
    }

    func cancel() {
        work?.cancel()
        deadline?.cancel()
        if case .ready(let controller) = phase { controller.cancel() }
    }
}
