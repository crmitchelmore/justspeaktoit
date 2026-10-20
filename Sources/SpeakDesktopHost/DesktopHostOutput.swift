import Foundation
import SpeakDesktop

/// Text-output options and the field captured for a recording or explicit
/// History paste. Imports and History retries never carry output authority.
package struct DesktopHostRecordingOutput<Platform: DesktopHostPlatform>: Sendable {
    package let options: Platform.TextOutputOptions
    package let target: Platform.InsertionTarget?

    package init(options: Platform.TextOutputOptions, target: Platform.InsertionTarget?) {
        self.options = options
        self.target = target
    }
}

package struct DesktopHostOutputState<Platform: DesktopHostPlatform>: Sendable {
    package var task: Task<Void, Never>?
    package var job: Platform.OutputJob?
    package var id: UUID?
    package var recordID: UUID?
    package var result: DesktopTextOutputResult?

    package init(
        task: Task<Void, Never>? = nil, job: Platform.OutputJob? = nil, id: UUID? = nil,
        recordID: UUID? = nil, result: DesktopTextOutputResult? = nil
    ) {
        self.task = task
        self.job = job
        self.id = id
        self.recordID = recordID
        self.result = result
    }
}

package enum DesktopHostOutputStart {
    case inserting, copying, busy, unavailable

    /// Status while the output runs; nil keeps the saved-record status.
    package var status: String? {
        switch self {
        case .inserting: return "Saved. Inserting into the original text field…"
        case .copying: return "Saved. Copying the transcript to the clipboard…"
        case .busy: return "Saved. An earlier output is still finishing; select Copy."
        case .unavailable: return nil
        }
    }
}

enum DesktopHostOutputPurpose: Sendable {
    case recording, historyPaste
}

extension DesktopHostController {
    /// Exactly one text output can be pending. A cancelled blocked
    /// provider retains its slot until it returns, while capture remains free
    /// to start and new transcripts remain safely available in History. The
    /// options belong to the submitted snapshot; current settings are never read here.
    /// The platform decides whether the options copy or insert into the target.
    func beginOutput(
        _ text: String, output: DesktopHostRecordingOutput<Platform>, recordID: UUID,
        purpose: DesktopHostOutputPurpose = .recording
    ) -> DesktopHostOutputStart {
        guard let job = Platform.makeOutputJob(options: output.options, target: output.target) else {
            return .unavailable
        }
        guard outputSlot.task == nil, !closed else { Platform.cancel(job); return .busy }
        let identifier = UUID()
        cancelCorrectionObservation()
        let learningRevision = correctionLearningRevision
        outputSlot = DesktopHostOutputState<Platform>(job: job, id: identifier, recordID: recordID)
        activeOperations += 1
        let effects = self.effects
        let worker = Task.detached(priority: .userInitiated) {
            effects.perform(job, text: text)
        }
        outputSlot.task = Task {
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                Platform.cancel(job)
                worker.cancel()
            }
            defer { finishOperation() }
            let completion = Task.isCancelled
                ? DesktopTextOutputResult(
                    .cancelled, status: "Output cancelled. Check the original field before retrying."
                )
                : result
            if outputSlot.id == identifier {
                outputSlot = DesktopHostOutputState<Platform>(recordID: recordID, result: completion)
            }
            guard !Task.isCancelled, !closed else { return }
            switch purpose {
            case .recording:
                beginCorrectionObservation(
                    job: job, text: text, recordID: recordID, revision: learningRevision, completion: completion
                )
                // A newer dictation owns the HUD by now if one started; this finishes only its own.
                finishHUD(recordID, completion.permitsAutomaticResume
                    ? .success(completion.status) : .failure(completion.status, headline: "Check text output"))
                guard recording == nil, selectedHistoryID == recordID else { return }
            case .historyPaste:
                guard canUseHistory else { return }
            }
            update(completion.status, state: 0)
        }
        return Platform.isClipboard(job) ? .copying : .inserting
    }

    func cancelOutput() {
        cancelCorrectionObservation()
        if let job = outputSlot.job { Platform.cancel(job) }
        outputSlot.task?.cancel()
        // Speech is output too: recording, import and close end Read aloud.
        stopReadAloud()
    }
}

extension DesktopHostController where Platform: DesktopHostDefaultTextOutputPlatform {
    package func pasteLastHistoryItem(
        target: Platform.InsertionTarget?, request: DesktopHistoryPasteAdmission.Request? = nil
    ) {
        guard !closed else { return }
        guard canUseHistory, outputSlot.task == nil else {
            update("Finish the current recording or text output before pasting from History.")
            return
        }
        guard let record = DesktopHistorySearch.ordered(Array(history.values)).first,
              let text = record.displayText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            update("Nothing to paste. The most recent History item has no text.")
            return
        }
        guard request?.isCurrent != false else {
            update("History paste was not sent: its captured target expired or the request was cancelled.")
            return
        }
        let output = DesktopHostRecordingOutput<Platform>(
            options: settings.textOutput ?? Platform.defaultTextOutput, target: target
        )
        switch beginOutput(text, output: output, recordID: record.id, purpose: .historyPaste) {
        case .inserting: update("Pasting the most recent History item into the captured text field…")
        case .copying: update("Copying the most recent History item to the clipboard…")
        case .busy: update("Another text output is still finishing. Try pasting from History again afterward.")
        case .unavailable:
            update("Could not paste from History. Focus a supported text field or choose clipboard-only output.")
        }
    }
}
