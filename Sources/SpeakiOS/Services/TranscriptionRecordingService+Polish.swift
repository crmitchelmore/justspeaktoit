#if os(iOS)
import Foundation
import SpeakCore
import UIKit

/// Background polish of a settled capture, owned by the stop that started it
/// so a superseded polish can never answer a newer run's waiter (#1015).
@MainActor
extension TranscriptionRecordingService {
    func startPostProcessing(
        text: String,
        historyItemID: UUID?,
        recordingWarning: String? = nil,
        completionID: UUID,
        runID: UUID?,
        assertion: BackgroundTaskAssertion
    ) {
        let settings = self.settings
        let model = settings.postProcessingModel
        let apiKey = settings.openRouterAPIKey
        let historyManager = self.historyManager
        let polish = self.polish
        let operation = AutomaticPolishOperation(
            isCurrent: { [weak self] in self?.latestCompletionID == completionID },
            successAndWait: { [weak self] polished, current in
                if current {
                    self?.sharedState.lastCompletedTranscript = polished
                    // Only the current run's polish may be waited on; an
                    // superseded one must not hand back the run before last.
                    self?.lastPolishedTranscript = polished
                }
                if let historyItemID {
                    // A loss notice recorded at stop survives the polish (issue #950).
                    await historyManager.setPostProcessedAndWait(
                        polished, for: historyItemID, preservingError: recordingWarning
                    )
                }
            },
            failureAndWait: { error in
                if let historyItemID {
                    await historyManager.setErrorAndWait(
                        [recordingWarning, error.localizedDescription].compactMap { $0 }.joined(separator: " "),
                        for: historyItemID
                    )
                }
            },
            completion: { [weak self] in
                if let historyItemID {
                    historyManager.endPostProcessing(for: historyItemID)
                }
                // Only the run that still owns the polish may release a
                // waiter. A superseded polish clearing the flag would let a
                // newer stop's `awaitPolishedTranscript` return before its own
                // polish had landed.
                if self?.polishingRunID == runID {
                    self?.isPostProcessing = false
                }
                assertion.end()
            }
        )
        operation.start(under: assertion, isActive: dependencies.applicationState() == .active) {
            try await polish(text, model, apiKey)
        }
    }

    /// Decides whether to run the background post-processor.
    ///
    /// Two paths trigger it:
    /// 1. Legacy callers (no explicit destination) honour the global
    ///    `autoPostProcess` toggle for backwards compatibility.
    /// 2. Hardware-trigger callers explicitly choose `.clipboardAndPostProcess`.
    func shouldPostProcess(
        destination: HardwareTriggerDestination,
        isLegacyCaller: Bool
    ) -> Bool {
        let settings = self.settings
        switch destination {
        case .clipboardAndPostProcess:
            return hasPolishingKey()
        case .clipboard:
            return isLegacyCaller && settings.autoPostProcess && hasPolishingKey()
        case .historyOnly, .auto:
            return false
        }
    }

    /// Waits, at most `timeout` seconds, for the background polish started by
    /// the stop that just happened, and returns what it produced.
    ///
    /// Returns `nil` — meaning "use the raw transcript" — in every case the
    /// polish did not deliver: no polish was started, it failed, it produced
    /// nothing, or it is still running when the budget runs out. It never
    /// returns a placeholder and never blocks past the deadline, because an
    /// intent the system kills for overrunning returns nothing at all, which
    /// is worse than the raw text.
    ///
    /// Polls rather than observes, matching the wait in `DictateIntent`: the
    /// polish runs in a detached `Task` whose completion this actor sees only
    /// through `isPostProcessing`.
    func awaitPolishedTranscript(timeout: TimeInterval, forRun runID: UUID?) async -> String? {
        guard timeout > 0, let runID, polishingRunID == runID else { return nil }
        // Monotonic: a wall-clock correction must not extend an intent's wait.
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while isPostProcessing, polishingRunID == runID, ContinuousClock.now < deadline {
            do {
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch {
                // Cancelled. Every later sleep would throw immediately, so
                // continuing here would spin the main actor until the deadline
                // and delay the actor-hosted polish it is waiting for.
                return nil
            }
        }
        // A newer stop took ownership of the polish state: whatever is in
        // `lastPolishedTranscript` is not this run's.
        guard polishingRunID == runID, !isPostProcessing else { return nil }
        return lastPolishedTranscript
    }
}
#endif
