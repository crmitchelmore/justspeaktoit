import Foundation

// Closed property values: every analytics dimension is a bounded enum.
public enum AnalyticsConsentState: String, Codable, CaseIterable, Sendable {
    case unknown
    case optedIn
    case optedOut
    public var permitsCollection: Bool { self == .optedIn }
}

public enum AnalyticsPrivacyClass: String, Codable, Sendable {
    case anonymousCounter = "anonymous_counter"
    case pseudonymous
}

public enum AnalyticsPlatform: String, Codable, Sendable { case macOS, iOS, android, windows, linux }

public enum AnalyticsDistributionChannel: String, Codable, Sendable {
    case direct, homebrew
    case macAppStore = "mac_app_store"
    case testFlight = "testflight"
    case appStore = "app_store"
    case googlePlay = "google_play"
    case development
}

public enum AnalyticsOnboardingEntryPoint: String, Codable, Sendable {
    case freshInstall = "fresh_install"
    case reset
}

public enum AnalyticsOnboardingStep: String, Codable, Sendable {
    case welcome
    case microphonePermission = "microphone_permission"
    case providerChoice = "provider_choice"
    case hotkeySetup = "hotkey_setup"
    case analyticsChoice = "analytics_choice"
}

public enum AnalyticsProviderType: String, Codable, Sendable {
    case alibaba, apple, azure, cartesia, deepgram, gladia, google, groq, local, meta, mistral, modulate, soniox
    case speechmatics, smallest, reson8, stepfun, other
    case assemblyAI = "assembly_ai"
    case elevenLabs = "eleven_labs"
    case openAI = "openai"
    case openRouter = "openrouter"
    case revAI = "rev_ai"
    case xAI = "xai"

    private static let liveProviderMapping: [LiveTranscriptionProviderID: AnalyticsProviderType] = [
        .alibaba: .alibaba,
        .apple: .apple,
        .azure: .azure,
        .deepgram: .deepgram,
        .cartesia: .cartesia,
        .gladia: .gladia,
        .google: .google,
        .modulate: .modulate,
        .assemblyai: .assemblyAI,
        .soniox: .soniox,
        .elevenlabs: .elevenLabs,
        .openai: .openAI,
        .speechmatics: .speechmatics,
        .xai: .xAI,
        .meta: .meta,
        .revai: .revAI,
        .mistral: .mistral,
        .reson8: .reson8
    ]

    public init(liveProvider: LiveTranscriptionProviderID) {
        self = Self.liveProviderMapping[liveProvider] ?? .other
    }
}

public enum AnalyticsEngineType: String, Codable, Sendable {
    case onDevice = "on_device"
    case cloud
}

public enum AnalyticsCountBucket: String, Codable, Sendable {
    case zero = "0"
    case one = "1"
    case twoToFive = "2-5"
    case sixToTwenty = "6-20"
    case overTwenty = ">20"
}

public enum AnalyticsDaysSinceInstallBucket: String, Codable, Sendable {
    case zero = "0"
    case one = "1"
    case twoToSeven = "2-7"
    case eightToThirty = "8-30"
    case overThirty = ">30"
}

public enum AnalyticsOptInSurface: String, Codable, Sendable { case onboarding, settings }
