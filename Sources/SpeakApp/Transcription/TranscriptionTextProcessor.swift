import AppKit
import Foundation
import SpeakCore

/// Processes transcription text to expand voice commands like "copy pasta" into actual content.
/// This runs after raw transcription but before personal lexicon and post-processing.
/// Thin macOS wrapper around SpeakCore's VoiceCommandProcessor, wiring in
/// NSPasteboard and AppSettings.
@MainActor
final class TranscriptionTextProcessor {
    private let processor: VoiceCommandProcessor

    init(appSettings: AppSettings) {
        processor = VoiceCommandProcessor(
            configuration: VoiceCommandProcessor.Configuration(
                isEnabled: { appSettings.voiceCommandsEnabled },
                customTriggers: { appSettings.clipboardInsertionTriggers },
                clipboardText: { NSPasteboard.general.string(forType: .string) }
            )
        )
    }

    /// Process transcription text, expanding any voice commands found.
    /// - Parameter text: Raw transcription text
    /// - Returns: Processed text with voice commands expanded
    func process(_ text: String) -> String {
        processor.process(text)
    }
}
