import Foundation

/// Provider-announced shutdowns for models the app still offers.
///
/// Until the shutdown day the entry stays selectable and its description says
/// when it stops working and what replaces it, so no price, language or feature
/// change happens silently. From the shutdown day (UTC) the catalogue hides the
/// entry and both transcription normalisers move saved selections to the
/// successor. The dates live in the app itself so builds that are never updated
/// still migrate before the provider starts rejecting requests.
public struct ModelRetirement: Sendable, Equatable {
    public enum Mode: Sendable, Equatable {
        case batch
        case live
        case speech
    }

    public let id: String
    public let mode: Mode
    /// First UTC day on which the provider no longer serves the model.
    public let shutdownDay: String
    /// Catalogue entry that replaces it, or `nil` when no compatible
    /// replacement exists on the same API.
    public let successorID: String?
    /// What changes for someone who moves to the successor.
    public let migrationNote: String

    public var shutdownDate: Date {
        Self.utcDate(shutdownDay) ?? .distantFuture
    }

    public func isRetired(at date: Date) -> Bool {
        date >= shutdownDate
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

    /// Sources: https://developers.openai.com/api/docs/deprecations and
    /// https://docs.mistral.ai/models/voxtral-mini-transcribe-26-02 (checked 2026-11).
    public static let all: [ModelRetirement] = [
        ModelRetirement(
            id: "openai/whisper-1", mode: .batch, shutdownDay: "2027-02-26",
            successorID: gptTranscribe,
            migrationNote: "moves to GPT Transcribe ($0.0045/min)."),
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
            successorID: gptTranscribe,
            migrationNote: "moves to GPT Transcribe, which has no speaker labels. "
                + "Choose Scribe v2, Soniox or Gemini 3.5 Transcribe to keep speakers."),
        ModelRetirement(
            id: "openai/gpt-4o-mini-transcribe-streaming", mode: .live, shutdownDay: "2027-02-26",
            successorID: gptLiveTranscribe,
            migrationNote: "moves to GPT Live Transcribe ($0.017/min, up from $0.003)."),
        ModelRetirement(
            id: "openai/gpt-4o-transcribe-streaming", mode: .live, shutdownDay: "2027-02-26",
            successorID: gptLiveTranscribe,
            migrationNote: "moves to GPT Live Transcribe ($0.017/min, up from $0.006)."),
        ModelRetirement(
            id: "mistral/voxtral-mini-latest", mode: .batch, shutdownDay: "2027-04-30",
            successorID: MistralVoxtral3.miniBatchID,
            migrationNote: "moves to Voxtral Mini Transcribe 3 ($0.0035/min, public preview)."),
        ModelRetirement(
            id: MistralVoxtralRealtime.liveCatalogID, mode: .live, shutdownDay: "2027-04-30",
            successorID: MistralVoxtral3.realtimeID,
            migrationNote: "moves to Voxtral Realtime 3 ($0.008/min, up from $0.006; public preview).")
    ] + OpenAITTSModel.allCases.map {
        // OpenAI's named successor, gpt-realtime-2.1-mini, is a Realtime
        // conversational model that `/v1/audio/speech` does not accept.
        ModelRetirement(
            id: $0.desktopModelIdentifier, mode: .speech, shutdownDay: "2027-01-06",
            successorID: nil,
            migrationNote: "OpenAI has no replacement on the speech API; choose another voice provider.")
    }

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

public extension OpenAITTSModel {
    /// Every OpenAI speech-API model shares one shutdown with no successor.
    var retirement: ModelRetirement? {
        ModelRetirements.retirement(for: desktopModelIdentifier)
    }
}
