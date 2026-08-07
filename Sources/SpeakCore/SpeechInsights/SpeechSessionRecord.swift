import Foundation

/// Minimal, platform-neutral projection of one dictation session used by the
/// speech-insights engine. Built from platform history records (Mac
/// `HistoryItem`, iOS history store) so the analytics layer never has to know
/// about persistence details.
///
/// Analytics always run over the raw (pre-polish) transcript so the numbers
/// reflect what the user actually said, not what a cleanup model rewrote.
public struct SpeechSessionRecord: Identifiable, Hashable, Sendable {
    public let id: UUID
    /// When the session started (history `createdAt`).
    public let startedAt: Date
    /// Raw transcript text analysed by the engine.
    public let text: String
    /// Recording duration in seconds; `0` when unknown.
    public let duration: TimeInterval
    /// Destination application the transcript was delivered to, when known.
    public let destinationApplication: String?
    /// Transcription model identifier, when known.
    public let modelIdentifier: String?

    public init(
        id: UUID,
        startedAt: Date,
        text: String,
        duration: TimeInterval,
        destinationApplication: String? = nil,
        modelIdentifier: String? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.text = text
        self.duration = duration
        self.destinationApplication = destinationApplication
        self.modelIdentifier = modelIdentifier
    }
}
