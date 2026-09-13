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

    public init(
        keywords: [String] = [],
        assemblyAIKeyterms: [String] = [],
        modulate: ModulateLiveOptions = .none
    ) {
        self.keywords = keywords
        self.assemblyAIKeyterms = assemblyAIKeyterms
        self.modulate = modulate
    }
}
