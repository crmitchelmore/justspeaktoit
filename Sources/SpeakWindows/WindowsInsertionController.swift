import Foundation
import SpeakWindowsPlatform
import CWindowsSupport

/// Automatic output authority for one recording: the text output options
/// persisted when it started and the field captured at its hotkey, if any.
/// Imports and History retries never carry one.
struct WindowsRecordingOutput: Sendable {
    let options: WindowsTextOutputOptions
    let target: WindowsInsertionTarget?
}

/// One automatic output owned by the controller's single output slot.
enum WindowsOutputJob: Sendable {
    /// Insert into the field captured at the recording hotkey.
    case insertion(WindowsInsertionTarget, WindowsTextOutputOptions)
    /// Copy without a destination, including for recordings started with
    /// Record in this window, which have no captured field.
    case clipboard(WindowsClipboardOutput)

    /// Nonblocking. A native operation already committed completes and is
    /// reported; nothing starts afterwards.
    func cancel() {
        switch self {
        case .insertion(let target, _): target.cancel()
        case .clipboard(let clipboard): clipboard.cancel()
        }
    }

    /// Blocking native output; never on the UI thread or the controller.
    func perform(_ text: String) -> String {
        guard !Task.isCancelled else { return "Output cancelled. Saved to History." }
        switch self {
        case .clipboard(let clipboard):
            do {
                try clipboard.copy(text)
                return "Transcript copied to the clipboard and saved to History."
            } catch {
                return "Saved. The transcript could not be copied; select Copy. \(error.localizedDescription)"
            }
        case .insertion(let target, let options):
            do {
                return WindowsInsertionStatus.message(for: try target.insert(text, options: options))
            } catch let failure as WindowsTextOutputError {
                return WindowsInsertionStatus.message(for: failure)
            } catch {
                return "Saved. Automatic insertion unavailable; select Copy. \(error.localizedDescription)"
            }
        }
    }
}

struct WindowsOutputState: Sendable {
    var task: Task<Void, Never>?
    var job: WindowsOutputJob?
    var id: UUID?
}

enum WindowsOutputStart {
    case inserting, copying, busy, unavailable

    /// Status while the output runs; nil keeps the saved-record status.
    var status: String? {
        switch self {
        case .inserting: return "Saved. Inserting into the original text field…"
        case .copying: return "Saved. Copying the transcript to the clipboard…"
        case .busy: return "Saved. An earlier output is still finishing; select Copy."
        case .unavailable: return nil
        }
    }
}

extension WindowsAppController {
    /// Exactly one automatic output can be pending. A cancelled blocked
    /// provider retains its slot until it returns, while capture remains free
    /// to start and new transcripts remain safely available in History. The
    /// options are the recording's own; current settings are never read here.
    /// Copying needs no captured field, and insertion only ever targets it.
    func beginOutput(_ text: String, output: WindowsRecordingOutput, recordID: UUID) -> WindowsOutputStart {
        let job: WindowsOutputJob
        if output.options.method == .clipboardOnly {
            guard let clipboard = try? WindowsClipboardOutput() else { return .unavailable }
            job = .clipboard(clipboard)
        } else if let target = output.target {
            job = .insertion(target, output.options)
        } else {
            return .unavailable
        }
        guard outputSlot.task == nil, !closed else { job.cancel(); return .busy }
        let identifier = UUID()
        outputSlot = WindowsOutputState(task: nil, job: job, id: identifier)
        activeOperations += 1
        let effects = self.effects
        let worker = Task.detached(priority: .userInitiated) {
            effects.perform(job, text: text)
        }
        outputSlot.task = Task {
            let status = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                job.cancel()
                worker.cancel()
            }
            if outputSlot.id == identifier { outputSlot = WindowsOutputState() }
            defer { finishOperation() }
            guard !Task.isCancelled, !closed, recording == nil, selectedHistoryID == recordID else { return }
            update(status, state: 0)
        }
        if case .clipboard = job { return .copying }
        return .inserting
    }

    func cancelOutput() {
        outputSlot.job?.cancel()
        outputSlot.task?.cancel()
        // Speech is output too: recording, import and close end Read aloud.
        stopReadAloud()
    }
}
