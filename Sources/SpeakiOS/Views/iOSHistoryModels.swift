#if os(iOS)
import Foundation
import SpeakCore
import SpeakSync

// MARK: - History Item Model

/// A single transcription history entry for iOS.
public struct iOSHistoryItem: Identifiable, Codable, Sendable { // swiftlint:disable:this type_name
    public let id: UUID
    public let createdAt: Date
    public let updatedAt: Date
    public let transcription: String
    /// Polished (post-processed) text, when the entry has been reprocessed.
    public let postProcessedTranscription: String?
    public let model: String
    public let duration: TimeInterval
    public let wordCount: Int
    public let originPlatform: String
    /// Most recent error captured for this entry (e.g. a failed reprocess),
    /// surfaced in the history UI. Local-only — not synced.
    public let errorMessage: String?

    /// Optional local admission; never synchronized or treated as an observed provider.
    public let requestContext: RequestDiagnosticContext?
    /// Original typed capture outcome; not a post-processing result or provider claim.
    public let requestFailure: RequestDiagnosticContext.Failure?
    /// Local session details shown in History (models by phase, timings, trigger).
    /// Persisted under HistoryRecord's key names; never synchronized.
    public let modelUsages: [ApplicationModelUsage]?
    public let phaseTimestamps: ApplicationPhaseTimestamps?
    public let trigger: ApplicationHistoryTrigger?

    // Rich display metadata remains in memory only. Local admission and typed
    // failure keys persist separately; nil keeps the original ten-key encoding.
    private let sourceHistoryRecord: HistoryRecord?

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        transcription: String,
        postProcessedTranscription: String? = nil,
        model: String,
        duration: TimeInterval,
        wordCount: Int,
        originPlatform: String = "ios",
        errorMessage: String? = nil
    ) {
        self.init(
            id: id, createdAt: createdAt, updatedAt: updatedAt, transcription: transcription,
            postProcessedTranscription: postProcessedTranscription, model: model, duration: duration,
            wordCount: wordCount, originPlatform: originPlatform, errorMessage: errorMessage, requestContext: nil
        )
    }

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        transcription: String,
        postProcessedTranscription: String? = nil,
        model: String,
        duration: TimeInterval,
        wordCount: Int,
        originPlatform: String = "ios",
        errorMessage: String? = nil,
        requestContext: RequestDiagnosticContext?
    ) {
        self.init(
            id: id, createdAt: createdAt, updatedAt: updatedAt, transcription: transcription,
            postProcessedTranscription: postProcessedTranscription, model: model, duration: duration,
            wordCount: wordCount, originPlatform: originPlatform, errorMessage: errorMessage,
            requestContext: requestContext, requestFailure: nil
        )
    }

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        transcription: String,
        postProcessedTranscription: String? = nil,
        model: String,
        duration: TimeInterval,
        wordCount: Int,
        originPlatform: String = "ios",
        errorMessage: String? = nil,
        requestContext: RequestDiagnosticContext? = nil,
        requestFailure: RequestDiagnosticContext.Failure?
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.transcription = transcription
        self.postProcessedTranscription = postProcessedTranscription
        self.model = model
        self.duration = duration
        self.wordCount = wordCount
        self.originPlatform = originPlatform
        self.errorMessage = errorMessage
        self.requestContext = RequestDiagnosticContext.admissionOnly(requestContext)
        self.requestFailure = requestFailure.map {
            .init(stage: $0.stage, code: $0.code, domain: $0.domain, httpStatus: $0.httpStatus)
        }
        self.modelUsages = nil
        self.phaseTimestamps = nil
        self.trigger = nil
        self.sourceHistoryRecord = nil
    }

    /// The best available transcript for copy/display: polished if present, else raw.
    public var bestText: String {
        postProcessedTranscription ?? transcription
    }

    /// Whether a polished version exists.
    public var hasPolishedText: Bool {
        !(postProcessedTranscription ?? "").isEmpty
    }

    /// Returns a copy with the polished transcript set and any prior error cleared.
    public func withPostProcessed(_ text: String, updatedAt: Date = Date()) -> iOSHistoryItem {
        iOSHistoryItem(retaining: self.historyRecord.replacingLocalText(
            postProcessedTranscription: text, errorMessage: nil, updatedAt: updatedAt
        ), wordCount: self.wordCount)
    }

    /// Returns a copy carrying an error message without advancing its timestamp.
    public func withError(_ message: String?) -> iOSHistoryItem {
        iOSHistoryItem(retaining: self.historyRecord.replacingLocalText(
            postProcessedTranscription: self.postProcessedTranscription,
            errorMessage: message, updatedAt: self.updatedAt
        ), wordCount: self.wordCount)
    }

    /// Convert to a syncable entry for CloudKit.
    func toSyncable() -> SyncableHistoryEntry {
        SyncableHistoryEntry(
            id: id,
            createdAt: createdAt,
            rawTranscription: transcription,
            postProcessedText: postProcessedTranscription,
            model: model,
            duration: duration,
            wordCount: wordCount,
            originPlatform: originPlatform,
            updatedAt: updatedAt
        )
    }

    /// Create from a synced remote entry.
    static func fromSyncable(_ entry: SyncableHistoryEntry) -> iOSHistoryItem {
        iOSHistoryItem(
            id: entry.id,
            createdAt: entry.createdAt,
            updatedAt: entry.updatedAt,
            transcription: entry.rawTranscription ?? entry.postProcessedText ?? "",
            postProcessedTranscription: entry.postProcessedText,
            model: entry.model,
            duration: entry.duration,
            wordCount: entry.wordCount,
            originPlatform: entry.originPlatform
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case createdAt
        case updatedAt
        case transcription
        case postProcessedTranscription
        case model
        case duration
        case wordCount
        case originPlatform
        case errorMessage
        case requestContext
        case requestFailure
        case modelUsages
        case phaseTimestamps
        case trigger
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        transcription = try container.decode(String.self, forKey: .transcription)
        postProcessedTranscription = try container.decodeIfPresent(String.self, forKey: .postProcessedTranscription)
        model = try container.decode(String.self, forKey: .model)
        duration = try container.decode(TimeInterval.self, forKey: .duration)
        wordCount = try container.decode(Int.self, forKey: .wordCount)
        originPlatform = try container.decodeIfPresent(String.self, forKey: .originPlatform) ?? "ios"
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
        requestContext = RequestDiagnosticContext.admissionOnly(
            try? container.decodeIfPresent(RequestDiagnosticContext.self, forKey: .requestContext)
        )
        requestFailure = try? container.decodeIfPresent(RequestDiagnosticContext.Failure.self, forKey: .requestFailure)
        // Optional session details; an unreadable one never hides the transcript.
        let usages = try? container.decodeIfPresent([ApplicationModelUsage].self, forKey: .modelUsages)
        modelUsages = usages?.isEmpty == false ? usages : nil
        phaseTimestamps = try? container.decodeIfPresent(ApplicationPhaseTimestamps.self, forKey: .phaseTimestamps)
        trigger = try? container.decodeIfPresent(ApplicationHistoryTrigger.self, forKey: .trigger)
        sourceHistoryRecord = nil
    }
}

extension iOSHistoryItem {
    /// Rich metadata is lossless while this display adapter remains in memory.
    /// Native encoding persists only the original fields plus optional admission/failure;
    /// other rich metadata still requires the source record's own local encoding.
    public init(historyRecord record: HistoryRecord) {
        self.init(retaining: record, wordCount: record.wordCount ?? record.presentation.wordCount)
    }

    private init(retaining record: HistoryRecord, wordCount: Int) {
        self.id = record.id
        self.createdAt = record.createdAt
        self.updatedAt = record.updatedAt
        self.transcription = record.rawTranscription ?? ""
        self.postProcessedTranscription = record.postProcessedTranscription
        self.model = record.iosPresentation.modelIdentifiers.first ?? ""
        self.duration = record.recordingDuration
        self.wordCount = wordCount
        self.originPlatform = record.originPlatform
        self.errorMessage = record.errorMessage
        self.requestContext = RequestDiagnosticContext.admissionOnly(record.requestContext)
        self.requestFailure = record.requestFailure
        self.modelUsages = record.modelUsages.isEmpty ? nil : record.modelUsages
        self.phaseTimestamps = record.phaseTimestamps
        self.trigger = record.trigger
        self.sourceHistoryRecord = record
    }

    public var historyRecord: HistoryRecord {
        self.sourceHistoryRecord ?? HistoryRecord(
            id: self.id, createdAt: self.createdAt, updatedAt: self.updatedAt, modelUsages: self.modelUsages ?? [],
            rawTranscription: self.transcription, postProcessedTranscription: self.postProcessedTranscription,
            recordingDuration: self.duration, phaseTimestamps: self.phaseTimestamps, trigger: self.trigger,
            model: self.model, wordCount: self.wordCount,
            originPlatform: self.originPlatform, errorMessage: self.errorMessage, requestContext: self.requestContext,
            requestFailure: self.requestFailure
        )
    }

    var presentationItem: HistoryPresentationItem { self.historyRecord.iosPresentation }

    /// The "Session details" rows History shows for this entry.
    var sessionDetails: HistoryDetailSummary { HistoryDetailSummary(record: self.historyRecord) }

    /// Returns a copy carrying new session details without advancing its timestamp.
    func withSessionDetails(
        modelUsages: [ApplicationModelUsage]?, phaseTimestamps: ApplicationPhaseTimestamps?,
        trigger: ApplicationHistoryTrigger?
    ) -> iOSHistoryItem {
        iOSHistoryItem(retaining: self.historyRecord.replacingSessionDetails(
            modelUsages: modelUsages ?? [], phaseTimestamps: phaseTimestamps, trigger: trigger
        ), wordCount: self.wordCount)
    }

    /// Records which model polished this entry and how long it took.
    func withPostProcessingDetails(_ details: IOSPostProcessingDetails?) -> iOSHistoryItem {
        guard let details else { return self }
        let usages = (self.modelUsages ?? []).filter { $0.phase != .postProcessing }
            + [ApplicationModelUsage(modelIdentifier: details.model, phase: .postProcessing)]
        let times = self.phaseTimestamps
        return self.withSessionDetails(
            modelUsages: usages,
            phaseTimestamps: ApplicationPhaseTimestamps(
                recordingStarted: times?.recordingStarted, recordingEnded: times?.recordingEnded,
                transcriptionStarted: times?.transcriptionStarted, transcriptionEnded: times?.transcriptionEnded,
                postProcessingStarted: details.startedAt, postProcessingEnded: details.endedAt,
                outputDelivered: times?.outputDelivered
            ),
            trigger: self.trigger
        )
    }

    /// A remote copy replacing this row keeps the session details only this device recorded.
    func retainingLocalSessionDetails(of local: iOSHistoryItem) -> iOSHistoryItem {
        guard self.modelUsages == nil, self.phaseTimestamps == nil, self.trigger == nil else { return self }
        guard local.modelUsages != nil || local.phaseTimestamps != nil || local.trigger != nil else { return self }
        return self.withSessionDetails(
            modelUsages: local.modelUsages, phaseTimestamps: local.phaseTimestamps, trigger: local.trigger
        )
    }
}

/// What a finished capture observed about itself, recorded with its History entry.
struct IOSCaptureDetails: Sendable {
    var trigger: CaptureTrigger?
    var isBatch: Bool
    var recordingStarted: Date?
    var recordingEnded: Date
    var transcriptionEnded: Date

    /// `item` carrying this capture's trigger, transcription model and timings.
    func applied(to item: iOSHistoryItem, model: String) -> iOSHistoryItem {
        let usages = model.isEmpty ? [] : [ApplicationModelUsage(
            modelIdentifier: model, phase: self.isBatch ? .transcriptionBatch : .transcriptionLive
        )]
        // Matches the Mac: a live transcript streams while recording, so its
        // measured interval is the finalisation after stop.
        let times = ApplicationPhaseTimestamps(
            recordingStarted: self.recordingStarted, recordingEnded: self.recordingEnded,
            transcriptionStarted: self.recordingEnded, transcriptionEnded: self.transcriptionEnded
        )
        return item.withSessionDetails(
            modelUsages: usages, phaseTimestamps: times,
            trigger: self.trigger.map(ApplicationHistoryTrigger.init(captureTrigger:))
        )
    }
}

/// The polish that produced an entry's post-processed text.
struct IOSPostProcessingDetails: Sendable {
    let model: String
    let startedAt: Date
    let endedAt: Date
}

extension iOSHistoryItem {
    /// A new History row for a finished recording; `nil` when it produced no text.
    static func recordedTranscript(
        text: String, model: String, duration: TimeInterval, errorMessage: String?,
        requestContext: RequestDiagnosticContext? = nil, requestFailure: RequestDiagnosticContext.Failure? = nil,
        captureDetails: IOSCaptureDetails? = nil
    ) -> iOSHistoryItem? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let item = iOSHistoryItem(
            transcription: text, model: model, duration: duration,
            wordCount: text.split(separator: " ").count, errorMessage: errorMessage, requestContext: requestContext,
            requestFailure: requestFailure
        )
        return captureDetails?.applied(to: item, model: model) ?? item
    }
}
#endif
