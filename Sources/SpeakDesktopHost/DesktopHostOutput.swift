import Foundation

/// Automatic output authority for one recording: the text output options
/// persisted when it started and the field captured at its hotkey, if any.
/// Imports and History retries never carry one.
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

    package init(task: Task<Void, Never>? = nil, job: Platform.OutputJob? = nil, id: UUID? = nil) {
        self.task = task
        self.job = job
        self.id = id
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

extension DesktopHostController {
    /// Exactly one automatic output can be pending. A cancelled blocked
    /// provider retains its slot until it returns, while capture remains free
    /// to start and new transcripts remain safely available in History. The
    /// options are the recording's own; current settings are never read here.
    /// The platform decides whether the options copy or insert into the target.
    func beginOutput(
        _ text: String, output: DesktopHostRecordingOutput<Platform>, recordID: UUID
    ) -> DesktopHostOutputStart {
        guard let job = Platform.makeOutputJob(options: output.options, target: output.target) else {
            return .unavailable
        }
        guard outputSlot.task == nil, !closed else { Platform.cancel(job); return .busy }
        let identifier = UUID()
        outputSlot = DesktopHostOutputState<Platform>(task: nil, job: job, id: identifier)
        activeOperations += 1
        let effects = self.effects
        let worker = Task.detached(priority: .userInitiated) {
            effects.perform(job, text: text)
        }
        outputSlot.task = Task {
            let status = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                Platform.cancel(job)
                worker.cancel()
            }
            if outputSlot.id == identifier { outputSlot = DesktopHostOutputState<Platform>() }
            defer { finishOperation() }
            guard !Task.isCancelled, !closed, recording == nil, selectedHistoryID == recordID else { return }
            update(status, state: 0)
        }
        return Platform.isClipboard(job) ? .copying : .inserting
    }

    func cancelOutput() {
        if let job = outputSlot.job { Platform.cancel(job) }
        outputSlot.task?.cancel()
    }
}
