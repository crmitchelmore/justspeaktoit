import Foundation
import SpeakCore

extension DesktopHostController where Platform: DesktopHostReadAloudPlatform {
    func admitVoiceAudioConversion(_ format: VoiceAudioFormat) throws -> UUID? {
        guard format != .wav else { return nil }
        guard readAloudState.codecOperationID == nil else {
            throw VoiceAudioFormatError.unavailable(
                "The previous native voice conversion is still closing. Try again when it finishes.")
        }
        let identifier = UUID()
        readAloudState.codecOperationID = identifier
        return identifier
    }

    func finishVoiceAudioConversion(_ identifier: UUID?) {
        guard let identifier, readAloudState.codecOperationID == identifier else { return }
        readAloudState.codecOperationID = nil
    }

    package func saveVoiceAudioFormat(_ identifier: String) async -> String? {
        await withCheckedContinuation { continuation in
            beginVoiceAudioFormatSave(identifier) { _, failure in continuation.resume(returning: failure) }
        }
    }

    /// UI settings queues admit only; native codec discovery must not hold their shutdown drain.
    package func beginVoiceAudioFormatSave(
        _ identifier: String,
        completion: @escaping @Sendable (DesktopVoiceOutputSettings?, String?) -> Void
    ) {
        guard !closed else { completion(nil, "The Voice window is closed."); return }
        guard readAloudState.formatSaveTask == nil else {
            completion(voiceOutputSettings(), "The previous codec discovery is still closing. Choose again.")
            return
        }
        let original = voiceOutputSettings()
        let format: VoiceAudioFormat
        let selection: DesktopSpeechSelection
        do {
            format = try VoiceAudioFormat.storedValue(identifier)
            selection = try currentVoiceSelection()
        } catch {
            update("Voice file format was not changed: \(error.localizedDescription)")
            completion(original, error.localizedDescription); return
        }
        let revision = voiceSettingsRevision
        activeOperations += 1
        readAloudState.formatSaveTask = Task {
            defer { self.readAloudState.formatSaveTask = nil; self.finishOperation() }
            let failure = await self.applyVoiceAudioFormat(
                format, selection: selection, original: original, revision: revision)
            completion(self.closed ? nil : self.voiceOutputSettings(), failure)
        }
    }

    private func applyVoiceAudioFormat(
        _ format: VoiceAudioFormat, selection: DesktopSpeechSelection,
        original: DesktopVoiceOutputSettings, revision: UInt64
    ) async -> String? {
        do {
            try await Platform.requireVoiceAudioFormat(format, sampleRate: selection.sampleRate)
            try Task.checkCancellation()
            guard !closed, voiceSettingsRevision == revision, voiceOutputSettings() == original else {
                throw VoiceAudioFormatError.unavailable("Voice settings changed during codec discovery. Choose again.")
            }
            var changed = original
            changed.format = format.rawValue
            guard persistVoiceOutput(changed, message: "\(format.displayName) voice file format saved.") else {
                return "The voice file format could not be saved. The previous setting was kept."
            }
            return nil
        } catch {
            if !closed, !Task.isCancelled, voiceSettingsRevision == revision {
                update("Voice file format was not changed: \(error.localizedDescription)")
            }
            return error.localizedDescription
        }
    }
}
