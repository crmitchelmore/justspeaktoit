import Foundation
import SpeakCore
import SpeakDesktop
import SpeakWindowsPlatform
import CWindowsSupport

/// The Windows answers to the shared automation verbs, over the same
/// controller the window drives. Option rejection, file checks and error
/// mapping are the shared `AutomationCommandDispatcher` policy, so `speak`
/// behaves as it does against the Mac app.
final class WindowsAutomationHost: AutomationCommandHost, @unchecked Sendable {
    private let controller: WindowsAppController

    init(controller: WindowsAppController) { self.controller = controller }

    func automationStatus() async -> AutomationResult {
        AutomationResult(sessionActive: await controller.automationSessionActive())
    }

    func automationHistory(limit: Int) async -> [AutomationHistoryEntry] {
        await controller.automationHistory(limit: limit)
    }

    func automationTranscribeFile(at url: URL) async throws -> AutomationResult {
        try await controller.automationTranscribe(url)
    }

    func automationStartDictation() async throws -> AutomationResult {
        try await controller.automationStartDictation()
    }

    func automationStopDictation() async throws -> AutomationResult {
        try await controller.automationStopDictation()
    }
}

extension WindowsAppController {
    func automationSessionActive() -> Bool { recording != nil }

    /// Newest first, from every saved record rather than the visible search.
    func automationHistory(limit: Int) -> [AutomationHistoryEntry] {
        history.values.sorted { $0.createdAt > $1.createdAt }.prefix(limit).map { record in
            let text = record.displayText ?? ""
            return AutomationHistoryEntry(
                id: record.id.uuidString, text: text, createdAt: record.createdAt,
                model: record.modelIdentifier, durationSeconds: record.result?.duration,
                wordCount: AutomationHistoryEntry.wordCount(of: text)
            )
        }
    }

    /// Transcribes the file with the remembered batch model, like the Mac's
    /// automation transcription: nothing is added to History and nothing is
    /// inserted or copied.
    func automationTranscribe(_ url: URL) async throws -> AutomationResult {
        guard !closed else { throw AutomationError(code: .appUnavailable, message: "Just Speak to It is closing.") }
        let model = settings.batchModel ?? (WindowsModels.isLive(settings.model)
            ? ModelCatalog.defaultBatchTranscriptionModel : settings.model)
        guard DesktopTranscription.provider(for: model) != nil else {
            throw AutomationError(code: .transcriptionFailed, message: "Choose a batch transcription model first.")
        }
        let key = try effects.apiKey(name: credentialIdentifier(for: model))
        guard !key.isEmpty else {
            throw AutomationError(
                code: .transcriptionFailed,
                message: "Save an API key for \(ModelCatalog.friendlyName(for: model)) first."
            )
        }
        do {
            try WindowsNative.validateImport(url)
            let result = try await effects.transcribe(
                WindowsTranscriptionRequest(audio: url, model: model, key: key, duration: 0, language: nil), with: self
            )
            return AutomationResult(text: result.text, model: model, durationSeconds: result.duration)
        } catch {
            throw AutomationError(code: .transcriptionFailed, message: error.localizedDescription)
        }
    }

    /// Starts the same pipeline as Record, with no captured field, and returns
    /// once capture is live.
    func automationStartDictation() async throws -> AutomationResult {
        guard recording == nil, !busy else { throw AutomationError.dictationAlreadyRunning }
        await toggle(
            target: nil, modelIndex: selectedIndex(), deviceID: selectedMicrophone(), targetExecutablePath: nil,
            textOutput: textOutputOptions()
        )
        guard recording != nil else {
            throw AutomationError(code: .internalError, message: "Dictation could not start. See the app for details.")
        }
        return AutomationResult(sessionActive: true)
    }

    /// Stops the active session and returns its saved transcript.
    func automationStopDictation() async throws -> AutomationResult {
        guard let active = recording, !busy else { throw AutomationError.noDictationRunning }
        let id = active.record.id
        await toggle(
            target: nil, modelIndex: selectedIndex(), deviceID: selectedMicrophone(), targetExecutablePath: nil,
            textOutput: textOutputOptions()
        )
        let record = history[id]
        if let failure = record?.failure, record?.displayText == nil {
            throw AutomationError(code: .transcriptionFailed, message: failure)
        }
        return AutomationResult(
            text: record?.displayText ?? "", model: record?.modelIdentifier, durationSeconds: record?.result?.duration
        )
    }
}

/// Starts and stops the pipe server when the user allows automation, and
/// reports the outcome in the window's Settings menu and status line.
final class WindowsAutomationSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var server: WindowsAutomationPipeServer?
    private let controller: WindowsAppController

    init(controller: WindowsAppController) { self.controller = controller }

    /// Returns the state actually reached and a message for the status line.
    func apply(enabled: Bool) -> (enabled: Bool, message: String?) {
        lock.withLock {
            guard enabled else {
                server?.stop()
                server = nil
                return (false, nil)
            }
            if server?.isRunning == true { return (true, nil) }
            do {
                let created = WindowsAutomationPipeServer(pipeName: try WindowsAutomationPipeServer.defaultPipeName())
                let host = WindowsAutomationHost(controller: controller)
                try created.start { request in await AutomationCommandDispatcher.response(to: request, host: host) }
                server = created
                return (true, "Automation is on: the speak command can control this app for your Windows account.")
            } catch {
                return (false, "Automation could not start: \(error.localizedDescription)")
            }
        }
    }

    func stop() { _ = apply(enabled: false) }

    /// `apply` joins native threads; never on the UI thread or an actor.
    static func applyOffThread(
        _ automation: WindowsAutomationSwitch, enabled: Bool
    ) async -> (enabled: Bool, message: String?) {
        await withCheckedContinuation { continuation in
            Thread { continuation.resume(returning: automation.apply(enabled: enabled)) }.start()
        }
    }

    /// Restarts automation the user left on; a failure is shown with the ready status.
    static func restore(_ holder: WindowsEventContext) async {
        guard await holder.controller.automationEnabled() else { return }
        let reached = await applyOffThread(holder.automation, enabled: true)
        WindowsNative.automation(enabled: reached.enabled)
        if !reached.enabled, let message = reached.message { await holder.controller.setAutomationWarning(message) }
    }

    static func shutDown(_ holder: WindowsEventContext) async {
        let automation = holder.automation
        await Task.detached { automation.stop() }.value
    }
}

/// The Settings menu's automation item. Starting or stopping the pipe server
/// joins threads, so it runs off the UI thread and the settings queue's actor
/// hop; the menu then shows the state actually reached.
func automationEvent(requested: Bool, holder: WindowsEventContext) {
    holder.enqueueSettings {
        let reached = await WindowsAutomationSwitch.applyOffThread(holder.automation, enabled: requested)
        await holder.controller.saveAutomation(enabled: reached.enabled)
        WindowsNative.automation(enabled: reached.enabled)
        WindowsNative.update(reached.message ?? "Automation is off. The speak command cannot reach this app.")
    }
}

extension WindowsAppController {
    func automationEnabled() -> Bool { settings.automationEnabled ?? false }

    /// Shown with the ready status when saved automation could not restart.
    func setAutomationWarning(_ warning: String) {
        microphoneWarning = [microphoneWarning, warning].compactMap { $0 }.joined(separator: " ")
    }

    func saveAutomation(enabled: Bool) {
        guard !closed else { return }
        var changed = settings
        changed.automationEnabled = enabled
        do {
            try effects.writeSettings(
                JSONEncoder().encode(changed), to: directory.appendingPathComponent("settings.json")
            )
            settings = changed
        } catch { update("Could not save the automation setting: \(error.localizedDescription)") }
    }
}

extension WindowsNative {
    static func automation(enabled: Bool) {
        _ = jsti_window_set_automation(enabled ? 1 : 0)
    }
}
