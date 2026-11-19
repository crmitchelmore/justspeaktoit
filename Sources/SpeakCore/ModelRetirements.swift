import Foundation

/// Provider-announced shutdowns for models the app still offers.
///
/// Until the shutdown day the entry stays selectable and its description says
/// when it stops working and what replaces it. From the shutdown day (UTC) the
/// catalogue hides the entry. Saved selections move automatically only when the
/// successor is a verified equivalent: same request features, same response
/// shape and a generally available model. Otherwise the saved selection, and
/// with it the user's intent (speaker labels, timestamps, a Stable model), is
/// kept and requests fail with `ModelRetiredError` until the user chooses a
/// replacement. The dates live in the app so builds that are never updated
/// still stop calling a dead model.
public struct ModelRetirement: Sendable, Equatable {
    public enum Mode: Sendable, Equatable {
        case batch
        case live
        case speech
        case postProcessing
    }

    public let id: String
    public let mode: Mode
    /// First UTC day on which the provider no longer serves the model.
    public let shutdownDay: String
    /// Verified-equivalent catalogue entry saved selections move to, or `nil`
    /// when moving would change features or guarantees.
    public let successorID: String?
    /// Suggested explicit choice when there is no automatic successor.
    public let recommendedID: String?
    /// What changes for someone who moves to the successor.
    public let migrationNote: String

    public var shutdownDate: Date {
        Self.utcDate(shutdownDay) ?? .distantFuture
    }

    public func isRetired(at date: Date) -> Bool {
        date >= shutdownDate
    }

    public init(
        id: String, mode: Mode, shutdownDay: String,
        successorID: String? = nil, recommendedID: String? = nil, migrationNote: String
    ) {
        self.id = id
        self.mode = mode
        self.shutdownDay = shutdownDay
        self.successorID = successorID
        self.recommendedID = recommendedID
        self.migrationNote = migrationNote
    }

    /// Short, locale-independent notice appended to catalogue descriptions.
    public var notice: String {
        "Retiring \(Self.displayDay(shutdownDay)): \(migrationNote)"
    }

    static func utcDate(_ day: String) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private static func displayDay(_ day: String) -> String {
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]) else { return day }
        return "\(parts[2]) \(months[parts[1] - 1]) \(parts[0])"
    }
}

public enum ModelRetirements {
    private static let gptTranscribe = OpenAITranscriptionModels.gptTranscribeCatalogID
    private static let gptLiveTranscribe = OpenAITranscriptionModels.gptLiveTranscribeStreamingCatalogID

    /// Sources: https://developers.openai.com/api/docs/deprecations,
    /// https://docs.mistral.ai/models/voxtral-mini-transcribe-26-02 and
    /// https://openrouter.ai/api/v1/models (checked 2026-11).
    public static let all: [ModelRetirement] = [
        ModelRetirement(
            id: "openai/whisper-1", mode: .batch, shutdownDay: "2027-02-26",
            recommendedID: gptTranscribe,
            migrationNote: "choose GPT Transcribe ($0.0045/min). It returns no segment timestamps, "
                + "so this selection is not moved automatically."),
        ModelRetirement(
            id: "openai/gpt-4o-transcribe", mode: .batch, shutdownDay: "2027-02-26",
            successorID: gptTranscribe,
            migrationNote: "moves to GPT Transcribe ($0.0045/min)."),
        ModelRetirement(
            id: "openai/gpt-4o-mini-transcribe", mode: .batch, shutdownDay: "2027-02-26",
            successorID: gptTranscribe,
            migrationNote: "moves to GPT Transcribe ($0.0045/min, up from $0.003)."),
        ModelRetirement(
            id: "openai/gpt-4o-transcribe-diarize", mode: .batch, shutdownDay: "2027-02-26",
            migrationNote: "OpenAI has no speaker-labelling successor. Choose Scribe v2, Soniox or "
                + "Gemini 3.5 Transcribe to keep speakers; this selection is not moved automatically."),
        ModelRetirement(
            id: "openai/gpt-4o-mini-transcribe-streaming", mode: .live, shutdownDay: "2027-02-26",
            successorID: gptLiveTranscribe,
            migrationNote: "moves to GPT Live Transcribe ($0.017/min, up from $0.003)."),
        ModelRetirement(
            id: "openai/gpt-4o-transcribe-streaming", mode: .live, shutdownDay: "2027-02-26",
            successorID: gptLiveTranscribe,
            migrationNote: "moves to GPT Live Transcribe ($0.017/min, up from $0.006)."),
        // Voxtral 3 is a public preview; a Stable selection is never moved onto it.
        ModelRetirement(
            id: "mistral/voxtral-mini-latest", mode: .batch, shutdownDay: "2027-04-30",
            recommendedID: MistralVoxtral3.miniBatchID,
            migrationNote: "choose a replacement such as Voxtral Mini Transcribe 3 "
                + "($0.0035/min, public preview); this selection is not moved automatically."),
        ModelRetirement(
            id: MistralVoxtralRealtime.liveCatalogID, mode: .live, shutdownDay: "2027-04-30",
            recommendedID: MistralVoxtral3.realtimeID,
            migrationNote: "choose a replacement such as Voxtral Realtime 3 "
                + "($0.008/min, public preview); this selection is not moved automatically."),
        // OpenAI names gpt-audio-1.5 as the successor, but OpenRouter does not
        // list it (checked 2026-11-03), so no hosted ID is invented here.
        ModelRetirement(
            id: "openai/gpt-audio", mode: .batch, shutdownDay: "2027-01-20",
            recommendedID: gptTranscribe,
            migrationNote: "OpenRouter does not offer its successor. Choose GPT Transcribe or another "
                + "model; this selection is not moved automatically.")
    ] + postProcessing + OpenAITTSModel.allCases.map {
        // OpenAI's named successor, gpt-realtime-2.1-mini, is a Realtime
        // conversational model that `/v1/audio/speech` does not accept.
        ModelRetirement(
            id: $0.desktopModelIdentifier, mode: .speech, shutdownDay: "2027-01-06",
            recommendedID: OpenAIRealtimeSpeech.catalogID,
            migrationNote: "choose OpenAI Realtime 2.1 mini or another voice provider; "
                + "this selection is not moved automatically.")
    }

    /// Announced cleanup shutdowns. Empty while every superseded cleanup model has
    /// already been taken out of the catalogue: `CleanupModelRemovals` moves those
    /// selections at once rather than on their shutdown day.
    static let postProcessing: [ModelRetirement] = []

    public static func retirement(for id: String) -> ModelRetirement? {
        all.first { $0.id == id }
    }

    /// The successor a saved selection should use now, if its model has shut down.
    public static func successor(for id: String, mode: ModelRetirement.Mode, at date: Date = Date()) -> String? {
        guard let retirement = retirement(for: id), retirement.mode == mode, retirement.isRetired(at: date) else {
            return nil
        }
        return retirement.successorID
    }

    public static func isRetired(_ id: String, at date: Date = Date()) -> Bool {
        retirement(for: id)?.isRetired(at: date) ?? false
    }

    /// Throws when a saved selection names a shut-down model with no automatic
    /// successor, so the request fails with an actionable message instead of
    /// reaching the provider or silently switching models.
    public static func ensureAvailable(_ id: String, at date: Date = Date()) throws {
        guard let retirement = retirement(for: id), retirement.isRetired(at: date) else { return }
        throw ModelRetiredError(retirement: retirement)
    }

    /// Hides shut-down entries and labels those with an announced shutdown.
    public static func current(_ options: [ModelCatalog.Option], at date: Date = Date()) -> [ModelCatalog.Option] {
        options.compactMap { option in
            guard let retirement = retirement(for: option.id) else { return option }
            guard !retirement.isRetired(at: date) else { return nil }
            let description = [option.description, retirement.notice].compactMap { $0 }.joined(separator: " ")
            return ModelCatalog.Option(
                id: option.id,
                displayName: option.displayName,
                description: description,
                estimatedLatencyMs: option.estimatedLatencyMs,
                latencyTier: option.latencyTier,
                tags: option.tags,
                pricing: option.pricing,
                contextLength: option.contextLength
            )
        }
    }
}

/// A saved model has shut down and needs an explicit replacement choice.
public struct ModelRetiredError: LocalizedError, Equatable, Sendable {
    public let retirement: ModelRetirement

    public var errorDescription: String? {
        "\(retirement.id) was retired by its provider on \(retirement.shutdownDay). "
            + "Choose another model in Settings: \(retirement.migrationNote)"
    }
}

public extension OpenAITTSModel {
    /// Every OpenAI speech-API model shares one shutdown with no successor.
    var retirement: ModelRetirement? {
        ModelRetirements.retirement(for: desktopModelIdentifier)
    }
}
