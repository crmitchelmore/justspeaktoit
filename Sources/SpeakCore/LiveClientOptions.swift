/// Provider-specific preferences passed through the shared live-client factory.
public struct ModulateLiveOptions: Sendable, Equatable {
    public let speakerDiarization: Bool
    public let emotionSignal: Bool
    public let accentSignal: Bool
    public let piiPhiTagging: Bool

    public init(
        speakerDiarization: Bool = false,
        emotionSignal: Bool = false,
        accentSignal: Bool = false,
        piiPhiTagging: Bool = false
    ) {
        self.speakerDiarization = speakerDiarization
        self.emotionSignal = emotionSignal
        self.accentSignal = accentSignal
        self.piiPhiTagging = piiPhiTagging
    }

    public static let none = ModulateLiveOptions()
}

/// Options whose meaning differs between live transcription providers.
public struct LiveClientOptions: Sendable, Equatable {
    public let keywords: [String]
    public let assemblyAIKeyterms: [String]
    public let modulate: ModulateLiveOptions
    public let postStopFinalizeBudget: TimeInterval?
    public let stopGracePeriod: TimeInterval

    public init(
        keywords: [String] = [],
        assemblyAIKeyterms: [String] = [],
        modulate: ModulateLiveOptions = .none
    ) {
        self.keywords = keywords
        self.assemblyAIKeyterms = assemblyAIKeyterms
        self.modulate = modulate
        self.postStopFinalizeBudget = nil
        self.stopGracePeriod = 0
    }

    public init(
        keywords: [String],
        assemblyAIKeyterms: [String],
        modulate: ModulateLiveOptions,
        postStopFinalizeBudget: TimeInterval?,
        stopGracePeriod: TimeInterval
    ) {
        self.keywords = keywords
        self.assemblyAIKeyterms = assemblyAIKeyterms
        self.modulate = modulate
        self.postStopFinalizeBudget = Self.sanitized(postStopFinalizeBudget)
        self.stopGracePeriod = Self.sanitized(stopGracePeriod) ?? 0
    }

    private static func sanitized(_ value: TimeInterval?) -> TimeInterval? {
        guard let value, value.isFinite else { return nil }
        return max(0, value)
    }
}
