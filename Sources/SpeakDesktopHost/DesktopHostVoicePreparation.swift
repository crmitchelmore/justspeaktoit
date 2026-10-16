import Foundation
import SpeakCore
import SpeakDesktop

extension DesktopHostController {
    /// Only this operation's provider input is rendered. The captured source
    /// remains the display, History and retained-result provenance.
    func prepareVoiceSynthesisSource(
        _ original: VoiceOutputSourceSnapshot, selection: DesktopSpeechSelection,
        ticket: DesktopPlaybackRequests.Ticket
    ) async throws -> VoiceOutputSourceSnapshot {
        try checkVoicePreparation(ticket)
        guard !TranscriptPostProcessingPolicy.isEffectivelyEmptyTranscript(original.text) else {
            throw VoiceOutputSourceSnapshot.Failure.emptyText
        }
        let phonemes = selection.options.useSSML && selection.voice.supportsSSMLPhonemes
        if selection.options.useSSML &&
            (!phonemes || VoiceSynthesisMarkup.containsAuthoredMarkup(in: original.text)) {
            try DesktopSpeechSynthesis.validateSSMLInput(
                original.text, voice: selection.voice, options: selection.options)
            try checkVoicePreparation(ticket)
            return original
        }
        let entries: [PronunciationEntry]
        do {
            let vocabulary = try await vocabularyStore()
            try checkVoicePreparation(ticket)
            entries = try await Self.voicePronunciationSnapshot(vocabulary)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try checkVoicePreparation(ticket)
            throw DesktopHostError(message: "Pronunciation dictionary could not be loaded: "
                + error.localizedDescription)
        }
        try checkVoicePreparation(ticket)
        let renderer = PronunciationRenderer()
        let text = phonemes
            ? renderer.generateSSML(for: original.text, entries: entries, provider: selection.voice)
            : renderer.applyReplacements(to: original.text, entries: entries)
        guard !TranscriptPostProcessingPolicy.isEffectivelyEmptyTranscript(text) else {
            throw VoiceOutputSourceSnapshot.Failure.emptyText
        }
        let prepared = try VoiceOutputSourceSnapshot(
            source: original.source, text: text, recordID: original.recordID)
        try DesktopSpeechSynthesis.validateSSMLInput(text, voice: selection.voice, options: selection.options)
        try checkVoicePreparation(ticket)
        return prepared
    }

    private func checkVoicePreparation(_ ticket: DesktopPlaybackRequests.Ticket) throws {
        try Task.checkCancellation()
        guard !closed, playbackRequests.isCurrent(ticket) else { throw CancellationError() }
    }

    @VocabularyActor
    private static func voicePronunciationSnapshot(_ vocabulary: DesktopVocabulary) throws -> [PronunciationEntry] {
        if let error = vocabulary.loadError { throw error }
        return vocabulary.entries
    }
}
