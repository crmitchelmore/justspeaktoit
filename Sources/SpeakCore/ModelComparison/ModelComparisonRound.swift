import Foundation

// MARK: - Compare Models: shared data model
//
// A comparison round sends one audio sample through several transcription
// models and records each model's raw transcript, latency and estimated cost.
// The user judges the transcripts blind — they are shown in a random order
// with the model names hidden — and ranks every entry. The ranking and the
// blind order are stored with the round so reveals, exports and the
// scoreboard stay consistent on every device the round syncs to (issue #1101).

/// How the audio for a round reached the models.
public enum ModelComparisonInputMode: String, Codable, Hashable, Sendable, CaseIterable {
    /// Live microphone fan-out: every model streamed the same capture.
    case streaming
    /// A single imported audio file.
    case file
    /// One round of a multi-sample batch.
    case batch

    public var displayName: String {
        switch self {
        case .streaming: return "Streaming"
        case .file: return "File"
        case .batch: return "Batch"
        }
    }
}

/// Identifies the audio a round was judged on without storing the audio.
public struct ModelComparisonSample: Codable, Hashable, Sendable {
    /// A user-recognisable name: the file name for imports, or a timestamped
    /// label for microphone captures.
    public let name: String
    /// SHA-256 of the audio bytes as lowercase hex, when known.
    public let contentHash: String?
    public let durationSeconds: Double

    public init(name: String, contentHash: String?, durationSeconds: Double) {
        self.name = name
        self.contentHash = contentHash
        self.durationSeconds = durationSeconds
    }
}

/// One model's result within a round.
public struct ModelComparisonEntry: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let modelID: String
    public let modelDisplayName: String
    public let providerDisplayName: String
    /// The raw model output. Post-processing is never applied.
    public var transcript: String
    /// A failure message when the model produced no transcript.
    public var errorDescription: String?
    /// Streaming only: capture start to the first non-empty partial.
    public var timeToFirstPartialMs: Int?
    /// Streaming: stop to final transcript. File: request to response.
    public var timeToFinalMs: Int?
    /// Estimated cost of this run in US dollars, when pricing is known.
    public var estimatedCostUSD: Decimal?

    public init(
        id: UUID = UUID(),
        modelID: String,
        modelDisplayName: String,
        providerDisplayName: String,
        transcript: String = "",
        errorDescription: String? = nil,
        timeToFirstPartialMs: Int? = nil,
        timeToFinalMs: Int? = nil,
        estimatedCostUSD: Decimal? = nil
    ) {
        self.id = id
        self.modelID = modelID
        self.modelDisplayName = modelDisplayName
        self.providerDisplayName = providerDisplayName
        self.transcript = transcript
        self.errorDescription = errorDescription
        self.timeToFirstPartialMs = timeToFirstPartialMs
        self.timeToFinalMs = timeToFinalMs
        self.estimatedCostUSD = estimatedCostUSD
    }

    public var didFail: Bool { errorDescription != nil }
}

/// The user's blind ranking of one entry: 1 is best.
public struct ModelComparisonRanking: Codable, Hashable, Sendable {
    public let entryID: UUID
    public let rank: Int

    public init(entryID: UUID, rank: Int) {
        self.entryID = entryID
        self.rank = rank
    }
}

/// One judged (or not yet judged) comparison of a sample across N models.
public struct ModelComparisonRound: Codable, Identifiable, Hashable, Sendable {
    /// Bumped when the encoded shape changes incompatibly.
    public static let schemaVersion = 1

    public let id: UUID
    public let createdAt: Date
    public var updatedAt: Date
    public let inputMode: ModelComparisonInputMode
    public let sample: ModelComparisonSample
    public let language: String?
    public let originPlatform: String
    public var entries: [ModelComparisonEntry]
    /// Entry ids in the order the transcripts were shown for judging.
    public let blindOrder: [UUID]
    /// Set once the user has ranked every entry.
    public var rankings: [ModelComparisonRanking]?
    public var judgedAt: Date?

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        inputMode: ModelComparisonInputMode,
        sample: ModelComparisonSample,
        language: String?,
        originPlatform: String,
        entries: [ModelComparisonEntry],
        blindOrder: [UUID],
        rankings: [ModelComparisonRanking]? = nil,
        judgedAt: Date? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.inputMode = inputMode
        self.sample = sample
        self.language = language
        self.originPlatform = originPlatform
        self.entries = entries
        self.blindOrder = blindOrder
        self.rankings = rankings
        self.judgedAt = judgedAt
    }

    public var isValid: Bool {
        let ids = Set(entries.map(\.id))
        return !entries.isEmpty && ids.count == entries.count
            && blindOrder.count == entries.count && Set(blindOrder) == ids
            && sample.durationSeconds.isFinite && sample.durationSeconds >= 0
            && (rankings == nil || Self.isCompleteRanking(rankings ?? [], for: entries))
    }

    public var isJudged: Bool { isValid && rankings != nil }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        inputMode = try values.decode(ModelComparisonInputMode.self, forKey: .inputMode)
        sample = try values.decode(ModelComparisonSample.self, forKey: .sample)
        language = try values.decodeIfPresent(String.self, forKey: .language)
        originPlatform = try values.decode(String.self, forKey: .originPlatform)
        entries = try values.decode([ModelComparisonEntry].self, forKey: .entries)
        blindOrder = try values.decode([UUID].self, forKey: .blindOrder)
        rankings = try values.decodeIfPresent([ModelComparisonRanking].self, forKey: .rankings)
        judgedAt = try values.decodeIfPresent(Date.self, forKey: .judgedAt)
        guard isValid else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Invalid comparison identities or ranking"))
        }
    }

    /// Entries in blind display order. Entries missing from `blindOrder`
    /// (which cannot happen for rounds this code creates) trail in id order
    /// so nothing is ever hidden.
    public var entriesInBlindOrder: [ModelComparisonEntry] {
        guard isValid else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        var ordered = blindOrder.compactMap { byID[$0] }
        let seen = Set(ordered.map(\.id))
        ordered += entries.filter { !seen.contains($0.id) }.sorted { $0.id.uuidString < $1.id.uuidString }
        return ordered
    }

    /// The blind label ("A", "B", …) for an entry, by its blind position.
    public func blindLabel(for entryID: UUID) -> String {
        guard let index = entriesInBlindOrder.firstIndex(where: { $0.id == entryID }) else { return "?" }
        return Self.blindLabel(at: index)
    }

    public static func blindLabel(at index: Int) -> String {
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        guard index >= 0 else { return "?" }
        if index < letters.count { return String(letters[index]) }
        return "\(letters[index % letters.count])\(index / letters.count + 1)"
    }

    public func rank(for entryID: UUID) -> Int? {
        rankings?.first(where: { $0.entryID == entryID })?.rank
    }

    /// Records a complete ranking. Every entry must receive a distinct rank
    /// from 1 to the number of entries, or the round is left unchanged and
    /// `false` is returned.
    @discardableResult
    public mutating func judge(rankings: [ModelComparisonRanking], at date: Date = Date()) -> Bool {
        guard Self.isCompleteRanking(rankings, for: entries) else { return false }
        self.rankings = rankings.sorted { $0.rank < $1.rank }
        judgedAt = date
        updatedAt = date
        return true
    }

    public static func isCompleteRanking(
        _ rankings: [ModelComparisonRanking],
        for entries: [ModelComparisonEntry]
    ) -> Bool {
        guard rankings.count == entries.count, !entries.isEmpty else { return false }
        let entryIDs = Set(entries.map(\.id))
        guard entryIDs.count == entries.count else { return false }
        let rankedIDs = Set(rankings.map(\.entryID))
        let ranks = Set(rankings.map(\.rank))
        return rankedIDs == entryIDs && ranks == Set(1...entries.count)
    }

    /// A random blind order for `entries`, drawn from `generator` so tests can
    /// pin the shuffle while the app uses the system generator.
    public static func makeBlindOrder<G: RandomNumberGenerator>(
        for entries: [ModelComparisonEntry],
        using generator: inout G
    ) -> [UUID] {
        entries.map(\.id).shuffled(using: &generator)
    }

    public static func makeBlindOrder(for entries: [ModelComparisonEntry]) -> [UUID] {
        var generator = SystemRandomNumberGenerator()
        return makeBlindOrder(for: entries, using: &generator)
    }
}
