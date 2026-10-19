import Foundation
import SpeakDesktopHost
import SpeakWindowsPlatform

enum WindowsVoiceEdit {
    static func toggle(_ holder: WindowsEventContext) {
        // Retain the hotkey's field before the settings queue or any actor hop.
        let captured = Result {
            let target = try WindowsInsertionTarget.captureVoiceEdit()
            return (target: target, path: try target.executablePathChecked())
        }
        let source = DesktopHostVoiceEditSource(
            executablePath: (try? captured.get())?.path,
            capture: { try await captured.get().target.selectedText() },
            replace: { text in try await replace(text, target: captured.get().target) },
            cancel: {
                if case .success(let captured) = captured { captured.target.cancel() }
            }
        )
        holder.enqueueSettings {
            let deviceID = await holder.controller.selectedMicrophone()
            await holder.controller.toggleVoiceEdit(source: source, deviceID: deviceID)
        }
    }

    private static func replace(_ text: String, target: WindowsInsertionTarget) async throws -> String {
        let work = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try target.insert(text, options: .init())
        }
        let outcome: WindowsInsertionTarget.Outcome
        do {
            outcome = try await withTaskCancellationHandler {
                let outcome = try await work.value
                try Task.checkCancellation()
                return outcome
            } onCancel: {
                target.cancel()
                work.cancel()
            }
        } catch {
            try Task.checkCancellation()
            let native = error as? WindowsTextOutputError
            var reason = error.localizedDescription
            if native?.clipboard == .restoreFailed || native?.clipboard == .restoredPartially {
                reason += " The previous clipboard could not be fully restored."
            }
            return try recover(
                text, target: target, reason: reason, ambiguous: native?.mayHaveInserted == true
            )
        }
        if outcome.verified && outcome.fieldIdentity {
            switch outcome.clipboard {
            case .restoreFailed, .restoredPartially:
                return "Voice edit replaced the selection, but the previous clipboard could not be fully restored."
            case .changedMeanwhile:
                return "Voice edit replaced the selection. A newer clipboard change was preserved."
            case .transcriptLeft:
                return "Voice edit replaced the selection. The rewrite remains on the clipboard."
            case .untouched, .restored:
                return "Voice edit: the captured selection was replaced."
            }
        }
        return try recover(
            text, target: target, reason: "Replacement was not confirmed.", ambiguous: true
        )
    }

    private static func recover(
        _ text: String, target: WindowsInsertionTarget, reason: String, ambiguous: Bool
    ) throws -> String {
        try Task.checkCancellation()
        do { try target.copy(text) } catch {
            throw WindowsTextOutputError(
                "\(reason) The rewrite could not be copied either: \(error.localizedDescription)",
                mayHaveInserted: ambiguous
            )
        }
        return ambiguous
            ? "Voice edit may have reached the app. Rewrite copied; check the original before pasting. \(reason)"
            : "Voice edit was not applied. Rewrite copied for manual paste. \(reason)"
    }
}
