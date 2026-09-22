import Foundation
import CWindowsSupport
import SpeakDesktop

extension WindowsAppController {
    func selectHistory(_ identifier: String) {
        guard canUseHistory, let id = UUID(uuidString: identifier),
              let record = history[id] else { return }
        selectedHistoryID = id
        transcript = record.displayText ?? ""
        let status = record.failure ?? record.postProcessingFailure.map { "Post-processing failed: \($0)" }
            ?? "Saved transcript. Retry uses this recording’s original model."
        update(status, transcript: transcript)
    }

    func retryHistory(_ identifier: String) async {
        guard canUseHistory, let id = UUID(uuidString: identifier),
              let record = history[id] else { return }
        guard DesktopTranscription.provider(for: record.modelIdentifier) != nil else {
            update("This used a live model. Open its audio, then choose Batch and import it to transcribe again.")
            return
        }
        busy = true
        activeOperations += 1
        defer { busy = false; finishOperation() }
        selectedHistoryID = id
        await transcribe(record, duration: record.result?.duration ?? 0, target: nil)
    }

    func exportHistory(_ identifier: String, path: String) async {
        guard !closed, let id = UUID(uuidString: identifier), history[id] != nil else { return }
        activeOperations += 1
        defer { finishOperation() }
        do {
            try await store.exportTranscript(id: id, to: URL(fileURLWithPath: path))
            update("Transcript exported.")
        } catch { update("Could not export transcript: \(error.localizedDescription)") }
    }

    func openHistoryAudio(_ identifier: String) async {
        guard !closed, let id = UUID(uuidString: identifier), let record = history[id] else { return }
        activeOperations += 1
        defer { finishOperation() }
        do {
            let audio = try await store.audioURL(for: record)
            guard !closed else { return }
            try audio.path.withCString { path in
                try WindowsNative.checked { jsti_shell_open_file(path, $0, $1) }
            }
        } catch { update("Could not open recording: \(error.localizedDescription)") }
    }

}
