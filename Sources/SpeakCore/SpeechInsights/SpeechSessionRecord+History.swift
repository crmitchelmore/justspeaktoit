import Foundation

extension SpeechSessionRecord {
    /// Projects one History entry into the engine's input, the same way on
    /// every Apple platform. Analytics run on the raw (pre-polish) transcript;
    /// the processed text is only a fallback for entries that never stored a
    /// raw transcript. Entries without text are skipped (`nil`).
    public init?(
        historyID id: UUID,
        createdAt: Date,
        rawTranscription: String?,
        postProcessedTranscription: String?,
        recordingDuration: TimeInterval,
        phaseTimestamps: ApplicationPhaseTimestamps?,
        destinationApplication: String? = nil,
        modelIdentifier: String? = nil
    ) {
        let raw = rawTranscription.flatMap { Self.hasText($0) ? $0 : nil }
        guard let text = raw ?? postProcessedTranscription, Self.hasText(text) else { return nil }
        self.init(
            id: id,
            startedAt: createdAt,
            text: text,
            duration: Self.effectiveDuration(recordingDuration: recordingDuration, phaseTimestamps: phaseTimestamps),
            destinationApplication: destinationApplication,
            modelIdentifier: modelIdentifier
        )
    }

    /// A shared History record (the iOS History store's representation).
    public init?(historyRecord record: HistoryRecord) {
        self.init(
            historyID: record.id,
            createdAt: record.createdAt,
            rawTranscription: record.rawTranscription,
            postProcessedTranscription: record.postProcessedTranscription,
            recordingDuration: record.recordingDuration,
            phaseTimestamps: record.phaseTimestamps,
            destinationApplication: record.trigger?.destinationApplication,
            modelIdentifier: record.modelUsages.first { $0.phase != .postProcessing }?.modelIdentifier
                ?? record.modelsUsed.first ?? record.model
        )
    }

    /// The recorded duration, falling back to the recording phase timestamps
    /// when no explicit duration was captured.
    public static func effectiveDuration(
        recordingDuration: TimeInterval,
        phaseTimestamps: ApplicationPhaseTimestamps?
    ) -> TimeInterval {
        if recordingDuration > 0 {
            return recordingDuration
        }
        if let start = phaseTimestamps?.recordingStarted, let end = phaseTimestamps?.recordingEnded {
            return max(0, end.timeIntervalSince(start))
        }
        return 0
    }

    private static func hasText(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
