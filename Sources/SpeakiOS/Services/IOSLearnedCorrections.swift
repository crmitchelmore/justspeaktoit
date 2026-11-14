#if os(iOS)
import Foundation
import SpeakCore

/// Learned auto-corrections on iOS (F48, #1651).
///
/// The Just Speak Keyboard watches each transcript it inserts and posts the
/// words the user changed to an App Group inbox (`KeyboardCorrectionStore`).
/// This records them through the shared `AutoCorrectionDomain`, which counts
/// repeats and promotes a correction to a lexicon rule at the threshold, and
/// applies those rules to every finished transcript, as macOS does.
@MainActor
public final class IOSLearnedCorrections {
    public static let shared = IOSLearnedCorrections()

    public let lexicon: PersonalLexiconService
    public let engine: AutoCorrectionEngine
    private let inbox: KeyboardCorrectionStore
    private let settings: AppSettings
    private var ingestion: Task<Void, Never>?
    private let log = SpeakLogger.logger(category: "IOSLearnedCorrections")

    convenience init() {
        self.init(
            settings: .shared, inbox: .shared,
            lexiconStore: PersonalLexiconStore(), candidateStore: AutoCorrectionStore()
        )
    }

    init(
        settings: AppSettings,
        inbox: KeyboardCorrectionStore,
        lexiconStore: PersonalLexiconStoring,
        candidateStore: AutoCorrectionStoring
    ) {
        self.settings = settings
        self.inbox = inbox
        let lexicon = PersonalLexiconService(store: lexiconStore)
        self.lexicon = lexicon
        // Every recording passes the user's threshold explicitly.
        self.engine = AutoCorrectionEngine(
            store: candidateStore, lexiconService: lexicon,
            promotionThreshold: { AutoCorrectionLearningPolicy.defaultPromotionThreshold }
        )
    }

    /// Waits for the saved rules, so the first transcript after a cold launch
    /// is corrected too.
    public func waitUntilLoaded() async {
        await lexicon.waitUntilLoaded()
    }

    /// The text with every learned correction applied. Rules keep applying
    /// when learning is off, until the user removes them.
    public func apply(to text: String) -> String {
        guard !text.isEmpty else { return text }
        return lexicon.apply(to: text, context: .empty).transformedText
    }

    /// Records what the keyboard has posted since the last call. Concurrent
    /// callers share one pass, so no observation is counted twice.
    public func ingestKeyboardObservations() async {
        if let ingestion {
            await ingestion.value
            return
        }
        let task = Task { await self.ingestPending() }
        ingestion = task
        await task.value
        ingestion = nil
    }

    private func ingestPending() async {
        let enabled = settings.autoCorrectionsEnabled
        inbox.setLearningEnabled(enabled)
        let pending = inbox.pendingObservations()
        guard !pending.isEmpty else { return }
        defer { inbox.markProcessed(pending.map(\.id)) }
        // Posted before learning was turned off: dropped, never learned.
        guard enabled else { return }
        do {
            try await engine.domain.recordChanges(
                pending.map(\.change), app: nil, threshold: settings.autoCorrectionsPromotionThreshold
            )
        } catch {
            // Marked processed anyway: a partly recorded batch retried would
            // count its saved changes twice.
            log.error("Recording keyboard corrections failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
#endif
