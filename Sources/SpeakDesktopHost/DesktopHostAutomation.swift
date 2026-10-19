import Foundation
import SpeakCore
import SpeakDesktop

package protocol DesktopHostAutomationPlatform: DesktopHostDefaultTextOutputPlatform {}

extension DesktopHostController: AutomationCommandHost where Platform: DesktopHostAutomationPlatform {
    package func automationStatus() -> AutomationResult {
        AutomationResult(sessionActive: dictationSessionID != nil)
    }

    package func automationHistory(limit: Int) -> [AutomationHistoryEntry] {
        history.values.sorted { $0.createdAt > $1.createdAt }.prefix(max(0, limit)).map { record in
            let text = record.displayText ?? ""
            return AutomationHistoryEntry(
                id: record.id.uuidString, text: text, createdAt: record.createdAt,
                model: record.modelIdentifier, durationSeconds: record.recordingDuration,
                wordCount: AutomationHistoryEntry.wordCount(of: text)
            )
        }
    }

    /// A separately owned read-only command: no History record, output job,
    /// clipboard, profile actions or post-processing pipeline is started.
    package func automationTranscribeFile(at url: URL) async throws -> AutomationResult {
        guard isReady, !closed else { throw automationUnavailable }
        try Task.checkCancellation()
        guard automationTranscriptions.count < 4 else {
            throw AutomationError(code: .transcriptionFailed, message: "Automation transcription is busy.")
        }
        let profile = resolveSelectedProfile(
            defaultModel: settings.batchModel ?? (DesktopHostModels.isLive(settings.model)
                ? ModelCatalog.defaultBatchTranscriptionModel : settings.model),
            executablePath: nil
        )
        let model = profile.modelIdentifier
        let held = beginLocalUse(model)
        defer { endLocalUse(held) }
        do {
            let request = try automationFileRequest(url, profile: profile)
            let result = try await runAutomationFileCommand(request)
            try Task.checkCancellation()
            guard !closed else { throw automationUnavailable }
            return AutomationResult(text: result.text, model: model, durationSeconds: result.duration)
        } catch let error as AutomationError {
            throw error
        } catch is CancellationError {
            throw AutomationError(code: .appUnavailable, message: "Automation transcription was cancelled.")
        } catch {
            throw AutomationError(code: .transcriptionFailed, message: error.localizedDescription)
        }
    }

    private func automationFileRequest(
        _ url: URL, profile: DesktopProfileSession
    ) throws -> DesktopHostTranscriptionRequest {
        let model = profile.modelIdentifier
        guard DesktopHostModels.isLocal(model) || DesktopHostModels.provider(for: model) != nil,
              !DesktopHostModels.isLive(model) else {
            throw DesktopTranscriptionError.unsupportedModel
        }
        if let limitation = profile.blockingLimitation { throw DesktopHostError(message: limitation.message) }
        try DesktopHostImport.validate(url)
        try checkUploadSize(url, model: model)
        var request = DesktopHostTranscriptionRequest(
            audio: url, model: model, key: try requireCredentialOrLocalModel(model), duration: 0,
            language: profile.language, keywords: batchKeywords(for: model, options: profile.transcriptionOptions),
            azureEndpoint: azureResourceEndpoint()
        )
        request.historySaved = false
        request.modulateFeatures = profile.modulateBatchFeatures
        return request
    }

    private func runAutomationFileCommand(
        _ request: DesktopHostTranscriptionRequest
    ) async throws -> TranscriptionResult {
        let effects = effects
        let id = UUID()
        let task = Task {
            try Task.checkCancellation()
            let request = try await self.automationVocabularyRequest(request)
            try Task.checkCancellation()
            return try await effects.transcribe(request, with: self)
        }
        automationTranscriptions[id] = task
        activeOperations += 1
        defer { automationTranscriptions.removeValue(forKey: id); finishOperation() }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }

    private func automationVocabularyRequest(
        _ request: DesktopHostTranscriptionRequest
    ) async throws -> DesktopHostTranscriptionRequest {
        let vocabulary = try await vocabularyKeywords()
        var combined = DesktopHostTranscriptionRequest(
            audio: request.audio, model: request.model, key: request.key, duration: request.duration,
            language: request.language, keywords: request.keywords + vocabulary,
            azureEndpoint: request.azureEndpoint
        )
        combined.historySaved = request.historySaved
        combined.modulateFeatures = request.modulateFeatures
        return combined
    }

    package func automationStartDictation() async throws -> AutomationResult {
        guard isReady, !closed else { throw automationUnavailable }
        try Task.checkCancellation()
        guard dictationSessionID == nil, !busy, !handsFreeMachine.isArmed else {
            throw AutomationError.dictationAlreadyRunning
        }
        let index = selectedIndex()
        let profile = captureProfile(modelIndex: index, executablePath: nil)
        await toggleCaptured(
            target: nil, modelIndex: index, deviceID: selectedMicrophone(),
            textOutput: settings.textOutput ?? Platform.defaultTextOutput, profile: profile
        )
        guard await dictationSessionReady() else {
            throw AutomationError(
                code: .transcriptionFailed, message: "Dictation could not start. See the app for details."
            )
        }
        return AutomationResult(sessionActive: true)
    }

    package func automationStopDictation() async throws -> AutomationResult {
        guard isReady, !closed else { throw automationUnavailable }
        try Task.checkCancellation()
        guard let id = dictationSessionID, canStopDictationSession, !handsFreeMachine.isArmed else {
            throw AutomationError.noDictationRunning
        }
        await toggle(
            target: nil, modelIndex: selectedIndex(), deviceID: selectedMicrophone(),
            targetExecutablePath: nil, textOutput: settings.textOutput ?? Platform.defaultTextOutput
        )
        guard dictationSessionID != id, let record = history[id], record.result != nil,
              record.failure == nil, record.postProcessingFailure == nil else {
            throw AutomationError(
                code: .transcriptionFailed,
                message: history[id]?.failure ?? history[id]?.postProcessingFailure
                    ?? "Dictation did not complete. Captured audio is retained in History."
            )
        }
        return AutomationResult(
            text: record.displayText ?? "", model: record.modelIdentifier,
            durationSeconds: record.result?.duration, sessionActive: false
        )
    }
}

extension DesktopHostController {
    private var automationUnavailable: AutomationError {
        AutomationError(code: .appUnavailable, message: "Just Speak to It is not ready or is closing.")
    }

    package var automationDesired: Bool {
        settings.configuration?.values[ApplicationPreferenceKey.enableAutomationServer.rawValue]?.storage == .bool(true)
    }

    /// Retained or legacy requests are not evidence of device-local approval.
    package func automationEnabled() -> Bool {
        DesktopAutomationConsent.allowed(
            desired: automationDesired, localGrant: settings.automationLocalConsent,
            legacyGrant: settings.automationEnabled, requiresLocalGrant: true
        )
    }

    package func saveAutomationPreference(enabled: Bool) throws {
        guard !closed else { throw automationUnavailable }
        let changed = try automationSettings(enabled: enabled)
        if !enabled { settings = changed }
        do {
            try effects.writeSettings(
                JSONEncoder().encode(changed), to: directory.appendingPathComponent("settings.json")
            )
        } catch {
            if !enabled { throw automationRevocationPersistenceError(error) }
            throw error
        }
        settings = changed
    }

    func automationSettings(enabled: Bool) throws -> Settings {
        var changed = settings
        var values = try configuration().values
        values[ApplicationPreferenceKey.enableAutomationServer.rawValue] = AnyCodable(.bool(enabled))
        changed.configuration = try DesktopConfiguration(values: values)
        changed.automationLocalConsent = enabled
        changed.automationEnabled = nil
        return changed
    }

    func automationRevocationPersistenceError(_ error: Error) -> DesktopHostError {
        DesktopHostError(message: "Automation is off for this run, but its revocation could not be saved. "
            + "Restart may restore the previous local grant. \(error.localizedDescription)")
    }

    package func setAutomationPreferenceHandler(_ handler: @escaping @Sendable () async -> Void) {
        automationPreferenceChanged = handler
    }

    package func automationPreferenceDescription() -> String {
        automationDesired && !automationEnabled()
            ? "Imported automation preference is on, but local access is off. "
                + "Enable here to grant access on this computer."
            : "Automation is off. The speak command cannot reach this app."
    }
}
