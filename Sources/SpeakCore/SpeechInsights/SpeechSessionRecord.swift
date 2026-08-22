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

    /// Stable fingerprint over every aggregation input (`text`, `startedAt`,
    /// `duration`). Persisted per session in the aggregate so reconciliation
    /// can detect in-place edits (CloudKit merges, local reprocessing) to a
    /// record whose UUID was already processed.
    ///
    /// Deterministic across launches and devices (FNV-1a, unlike `Hasher`
    /// which is seeded per process). Extend the folded fields whenever a new
    /// dimension starts to influence aggregation.
    public var contentFingerprint: UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325 // FNV-1a offset basis
        let prime: UInt64 = 0x100_0000_01b3
        func fold(_ byte: UInt8) {
            hash = (hash ^ UInt64(byte)) &* prime
        }
        for byte in text.utf8 { fold(byte) }
        fold(0) // field separator
        withUnsafeBytes(of: startedAt.timeIntervalSince1970.bitPattern.littleEndian) {
            for byte in $0 { fold(byte) }
        }
        withUnsafeBytes(of: duration.bitPattern.littleEndian) {
            for byte in $0 { fold(byte) }
        }
        return hash
    }

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
