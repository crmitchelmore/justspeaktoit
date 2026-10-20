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
        if Platform.supportsObservationalCorrections {
            return correctionLearningNotice ?? (observationalCorrectionConsent
                ? "Observational learning allowed for this session. App-origin changes can also be learned. "
                    + "Only an admitted AT-SPI editable field is eligible; paste is never observed."
                : "Observational learning is off. Allow it explicitly for this session to observe bounded inserted "
                    // swiftlint:disable:next line_length
                    + "spans; app-origin formatting and changes can also be learned. Accessibility must already be enabled.")
        }
        if !correctionLearningApproved {
            return "Local approval required: Allow learning for this session to read only verified inserted text. "
                + "Imported preferences never grant this approval."
        }
        return correctionLearningNotice
            ?? "Learning allowed for this session; only confirmed, still-owned text ranges are observed."
    }

    func correctionLearningApproval(_ action: String, observationalToken: UInt64? = nil) throws -> String {
        if Platform.supportsObservationalCorrections, action == "allowLearning" || action == "stopLearning" {
            throw DesktopHostError(message: "Observational learning requires the generation-bound local "
                + "Allow or Stop control. Generic actions do not change session consent.")
        }
        let observational = action == "allowObservationalLearning" || action == "stopObservationalLearning"
        if observational {
            guard Platform.supportsObservationalCorrections, let token = observationalToken,
                  Platform.observationalCorrectionActionIsCurrent(action == "allowObservationalLearning", token: token)
            else {
                throw DesktopHostError(message: "This local observational consent action is stale. "
                    + "The latest Allow or Stop action is unchanged.")
            }
        }
        cancelCorrectionObservation()
        if action == "allowObservationalLearning" {
            guard Platform.supportsObservationalCorrections, correctionLearningEnabled,
                  Platform.correctionLearningUnavailable == nil else {
                _ = Platform.setObservationalCorrectionConsent(false, token: observationalToken)
                observationalCorrectionConsent = false
                throw DesktopHostError(message: correctionLearningStatus())
            }
            correctionLearningApproved = false
            observationalCorrectionConsent = Platform.setObservationalCorrectionConsent(true, token: observationalToken)
            guard observationalCorrectionConsent else {
                throw DesktopHostError(message: "Observational learning needs the current local in-app consent dialog. "
                    + "A queued or imported action cannot grant permission after Stop.")
            }
        } else if action == "stopObservationalLearning" {
            guard Platform.setObservationalCorrectionConsent(false, token: observationalToken) else {
                throw DesktopHostError(message: "This local Stop action is stale. The latest consent is unchanged.")
            }
            correctionLearningApproved = false
            observationalCorrectionConsent = false
        } else {
            revokeCorrectionLearningConsent()
        }
        if action == "allowLearning" {
            guard !Platform.supportsObservationalCorrections,
                  Platform.correctionLearningUnavailable == nil, correctionLearningEnabled else {
                throw DesktopHostError(message: correctionLearningStatus())
            }
            correctionLearningApproved = true
        }
        correctionLearningNotice = nil
        return correctionLearningStatus()
    }

    func revokeCorrectionLearningConsent() {
        correctionLearningApproved = false
        observationalCorrectionConsent = false
        Platform.setObservationalCorrectionConsent(false, token: nil)
    }

    private func permitsCorrectionLearning(_ provenance: DesktopCorrectionProvenance) -> Bool {
        switch provenance {
        case .acknowledgedInsertion: return correctionLearningApproved
        case .observationalATSPISpan:
            return Platform.supportsObservationalCorrections && observationalCorrectionConsent
        }
    }

    func beginCorrectionObservation(
        job: Platform.OutputJob, text: String, recordID: UUID, revision: UInt64,
        completion: DesktopTextOutputResult
    ) {
        guard !closed, revision == correctionLearningRevision,
              correctionLearningEnabled else { return }
        guard !Platform.isClipboard(job), let native = Platform.correctionReadback(job),
              permitsCorrectionLearning(native.provenance),
              (completion.disposition == .confirmedInsertion && native.provenance == .acknowledgedInsertion)
                || (completion.disposition == .observedInsertion && native.provenance == .observationalATSPISpan) else {
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
                  self.permitsCorrectionLearning(run.provenance), self.correctionLearningEnabled else { return }
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
