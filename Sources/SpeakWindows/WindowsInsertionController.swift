import Foundation
import SpeakWindowsPlatform
import CWindowsSupport

struct WindowsInsertionState: Sendable {
    var task: Task<Void, Never>?
    var target: WindowsInsertionTarget?
    var id: UUID?
}

extension WindowsAppController {
    /// Exactly one native insertion can be pending. A cancelled blocked
    /// provider retains its slot until it returns, while capture remains free
    /// to start and new transcripts remain safely available in History.
    func beginInsertion(_ text: String, to target: WindowsInsertionTarget, recordID: UUID) -> Bool {
        guard insertion.task == nil, !closed else { target.cancel(); return false }
        let identifier = UUID()
        let options = settings.textOutput ?? .init()
        insertion.id = identifier
        insertion.target = target
        activeOperations += 1
        let worker = Task.detached(priority: .userInitiated) {
            Self.deliver(text, to: target, options: options)
        }
        insertion.task = Task {
            let status = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                target.cancel()
                worker.cancel()
            }
            if insertion.id == identifier {
                insertion.task = nil
                insertion.target = nil
                insertion.id = nil
            }
            defer { finishOperation() }
            guard !Task.isCancelled, !closed, recording == nil, selectedHistoryID == recordID else { return }
            update(status, state: 0)
        }
        return true
    }

    func cancelInsertion() {
        insertion.target?.cancel()
        insertion.task?.cancel()
    }

    private nonisolated static func deliver(
        _ text: String, to target: WindowsInsertionTarget, options: WindowsTextOutputOptions
    ) -> String {
        guard !Task.isCancelled else { return "Insertion cancelled. Saved to History." }
        guard options.method != .clipboardOnly else {
            do {
                try target.copy(text)
                return "Transcript copied to the clipboard and saved to History."
            } catch {
                return "Saved. The transcript could not be copied; select Copy. \(error.localizedDescription)"
            }
        }
        do {
            return WindowsInsertionStatus.message(for: try target.insert(text, options: options))
        } catch let failure as WindowsTextOutputError {
            return WindowsInsertionStatus.message(for: failure)
        } catch {
            return "Saved. Automatic insertion unavailable; select Copy. \(error.localizedDescription)"
        }
    }
}
