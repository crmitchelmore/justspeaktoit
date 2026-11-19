#if os(iOS)
import AppIntents

/// An additive action: existing saved Shortcuts keep their String result types.
struct GetLastTranscriptEntityIntent: AppIntent {
    static var title: LocalizedStringResource { "Get Last Transcript" }
    static var description: IntentDescription {
        IntentDescription(
            """
            Returns the latest History item with its raw and polished text as separate properties. \
            For plain text, use Get Last Transcription.
            """,
            categoryName: "Transcripts"
        )
    }
    static var openAppWhenRun: Bool { false }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<TranscriptEntity> {
        .result(value: try await TranscriptEntityHistory().latestAndWait())
    }
}
#endif
