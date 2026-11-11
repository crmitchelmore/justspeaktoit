#if os(iOS)
import AppIntents
import Foundation
import SpeakCore

/// App Shortcuts provider exposing transcription actions (iOS 18+, includes recording).
@available(iOS 18, *)
struct TranscriptionShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartTranscriptionRecordingIntent(),
            phrases: [
                "Toggle recording with \(.applicationName)",
                "Transcribe with \(.applicationName)",
                "Record with \(.applicationName)"
            ],
            shortTitle: "Toggle Recording",
            systemImageName: "mic.fill"
        )

        AppShortcut(
            intent: StartTranscriptionIntent(),
            phrases: [
                "Start recording with \(.applicationName)",
                "Start transcription with \(.applicationName)",
                // The parameterised phrase is what makes a spoken destination
                // possible at all: "Start recording to History Only with
                // Just Speak to It".
                "Start recording to \(\.$destination) with \(.applicationName)"
            ],
            shortTitle: "Start Recording",
            systemImageName: "mic.badge.plus"
        )

        AppShortcut(
            intent: StopTranscriptionRecordingIntent(),
            phrases: [
                "Stop recording with \(.applicationName)",
                "Stop transcription with \(.applicationName)"
            ],
            shortTitle: "Stop Recording",
            systemImageName: "stop.fill"
        )

        // The one-shot action (#1011) had no phrase, so the only spoken way to
        // get text back was the two-step Start / "Stop dictation and get text"
        // pair. Every parameter it needs has a default, so a bare phrase runs.
        AppShortcut(
            intent: DictateIntent(),
            phrases: [
                "Dictate with \(.applicationName)",
                "Take a note with \(.applicationName)",
                "Dictate to \(\.$destination) with \(.applicationName)"
            ],
            shortTitle: "Dictate",
            systemImageName: "waveform.badge.mic"
        )

        AppShortcut(
            intent: StopDictationIntent(),
            phrases: [
                "Stop dictation and get text with \(.applicationName)",
                "Finish dictation with \(.applicationName)"
            ],
            shortTitle: "Stop and Get Text",
            systemImageName: "text.badge.checkmark"
        )

        AppShortcut(
            intent: GetLastTranscriptionIntent(),
            phrases: [
                "Get my last transcription from \(.applicationName)",
                "Get the last dictation from \(.applicationName)"
            ],
            shortTitle: "Last Transcription",
            systemImageName: "clock.arrow.circlepath"
        )

        AppShortcut(
            intent: CopyLastSentenceIntent(),
            phrases: [
                "Copy last sentence from \(.applicationName)",
                "Copy recent transcription from \(.applicationName)"
            ],
            shortTitle: "Copy Last Sentence",
            systemImageName: "doc.on.doc"
        )

        AppShortcut(
            intent: CopyFullTranscriptIntent(),
            phrases: [
                "Copy full transcript from \(.applicationName)",
                "Copy all transcription from \(.applicationName)"
            ],
            shortTitle: "Copy Full Transcript",
            systemImageName: "doc.on.doc.fill"
        )
    }
}
#endif
