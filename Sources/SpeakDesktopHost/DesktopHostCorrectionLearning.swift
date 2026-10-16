import Foundation
import SpeakCore
import SpeakDesktop

extension DesktopHostPlatform {
    package static var correctionLearningUnavailable: String? {
        "Correction learning is unavailable: this host cannot confirm and retain an inserted field's text range. "
            + "Stored candidates can still be reviewed and promoted."
    }
    package static func correctionReadback(_ job: OutputJob) -> (any DesktopCorrectionReadback)? { nil }
}

extension DesktopHostController {
    var correctionLearningEnabled: Bool {
        settings.configuration?.enabled(ApplicationPreferenceKey.autoCorrectionsEnabled.rawValue)
            ?? AutoCorrectionLearningPolicy.enabledByDefault
    }

    var correctionLearningThreshold: Int {
        Int(settings.configuration?.number(ApplicationPreferenceKey.autoCorrectionsPromotionThreshold.rawValue)
            ?? Double(AutoCorrectionLearningPolicy.defaultPromotionThreshold))
    }

    func cancelCorrectionObservation() {
        correctionLearningRevision &+= 1
        correctionObservation?.cancel()
        correctionObservation = nil
        correctionObservationTask?.cancel()
        correctionObservationTask = nil
    }

    func correctionLearningStatus() -> String {
        if let unavailable = Platform.correctionLearningUnavailable { return unavailable }
        if !correctionLearningEnabled {
            return "Automatic learning is off. Stored candidates remain available for manual review."
        }
        if !correctionLearningApproved {
            return "Local approval required: Allow learning for this session to read only verified inserted text. "
                + "Imported preferences never grant this approval."
        }
        return correctionLearningNotice
            ?? "Learning allowed for this session; only confirmed, still-owned text ranges are observed."
    }

    func correctionLearningApproval(_ action: String) throws -> String {
        cancelCorrectionObservation()
        correctionLearningApproved = false
        if action == "allowLearning" {
            guard Platform.correctionLearningUnavailable == nil, correctionLearningEnabled else {
                throw DesktopHostError(message: correctionLearningStatus())
            }
            correctionLearningApproved = true
        }
        correctionLearningNotice = nil
        return correctionLearningStatus()
    }

    func beginCorrectionObservation(
        job: Platform.OutputJob, text: String, recordID: UUID, revision: UInt64,
        completion: DesktopTextOutputResult
    ) {
        guard !closed, revision == correctionLearningRevision, correctionLearningApproved,
              correctionLearningEnabled else { return }
        guard completion.disposition == .confirmedInsertion, !Platform.isClipboard(job),
              let native = Platform.correctionReadback(job) else {
            correctionLearningNotice = "Learning skipped: clipboard-only or unconfirmed output has no owned text span."
            return
        }
        let run = DesktopCorrectionObservation(native: native)
        let threshold = correctionLearningThreshold
        correctionObservation = run
        correctionObservationTask = Task {
            await self.observeCorrection(run, text: text, recordID: recordID, revision: revision, threshold: threshold)
        }
    }

    private func observeCorrection(
        _ run: DesktopCorrectionObservation, text: String, recordID: UUID, revision: UInt64, threshold: Int
    ) async {
        defer {
            if revision == self.correctionLearningRevision {
                run.cancel()
                self.correctionObservation = nil
                self.correctionObservationTask = nil
            }
        }
        do {
            let edited = try await run.sample(original: text, wait: self.correctionObservationWait)
            guard !self.closed, revision == self.correctionLearningRevision, run.isCurrent,
                  self.correctionLearningApproved, self.correctionLearningEnabled else { return }
            let vocabulary = try await self.vocabularyStore()
            try await vocabulary.candidates.recordEdit(
                original: text, edited: edited, app: run.application, threshold: threshold,
                isCurrent: { run.isCurrent }
            )
            guard run.isCurrent, revision == self.correctionLearningRevision else { return }
            self.correctionLearningNotice = "Correction observation finished. "
                + "Review stored candidates for pending changes."
        } catch is CancellationError {
            return
        } catch {
            guard run.isCurrent, revision == self.correctionLearningRevision, !self.closed else { return }
            self.correctionLearningNotice = "Correction learning skipped: \(error.localizedDescription)"
        }
        if self.recording == nil, self.selectedHistoryID == recordID {
            self.update(self.correctionLearningStatus(), state: 0)
        }
    }
}
