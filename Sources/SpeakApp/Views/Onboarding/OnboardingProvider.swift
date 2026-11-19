import SpeakCore
import Foundation

// MARK: - Provider Info for Onboarding

// MARK: - Analytics helpers

extension OnboardingProvider {
    /// Maps the onboarding provider to the analytics provider type for event capture.
    var analyticsProviderType: AnalyticsProviderType {
        switch self {
        case .deepgram: return .deepgram
        case .soniox: return .soniox
        case .openai: return .openAI
        case .openrouter: return .openRouter
        case .revai: return .revAI
        case .meta: return .meta
        }
    }
}

extension OnboardingStep {
    /// Returns the analytics step used for `onboarding_step_completed` events,
    /// or `nil` for steps without a direct analytics equivalent.
    var analyticsStep: AnalyticsOnboardingStep? {
        switch self {
        case .welcome: return .welcome
        case .permissions: return .microphonePermission
        case .hotkey: return .hotkeySetup
        case .apiKey: return .providerChoice
        case .testRecording, .complete: return nil
        }
    }
}

// MARK: - Provider Info for Onboarding

enum OnboardingProvider: String, CaseIterable, Identifiable {
    case deepgram
    case soniox
    case openai
    case openrouter
    case revai
    case meta

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .deepgram: return "Deepgram"
        case .soniox: return "Soniox"
        case .openai: return "OpenAI Whisper"
        case .meta: return "Meta Muse"
        case .openrouter: return "OpenRouter"
        case .revai: return "Rev.ai"
        }
    }

    var signupURL: URL {
        switch self {
        case .deepgram: return URL(string: "https://console.deepgram.com/signup")!
        case .soniox: return URL(string: "https://console.soniox.com")!
        case .openai: return URL(string: "https://platform.openai.com/signup")!
        case .openrouter: return URL(string: "https://openrouter.ai/keys")!
        case .revai: return URL(string: "https://www.rev.ai/auth/signup")!
        case .meta: return URL(string: "https://llama.developer.meta.com")!
        }
    }

    var apiKeyInstructions: String {
        switch self {
        case .deepgram: return "Go to Settings → API Keys → Create Key"
        case .soniox: return "Go to Dashboard → API Keys → New API Key"
        case .openai: return "Go to API Keys → Create new secret key"
        case .openrouter: return "Go to Keys → Create Key"
        case .revai: return "Go to Access Token → Generate Token"
        case .meta: return "Open the Model API dashboard → API Keys → Create key"
        }
    }

    var freeCredits: String? {
        switch self {
        case .deepgram: return "Free tier includes $200 credit"
        case .soniox: return "Free tier includes $200 credit, real-time streaming STT"
        case .openai: return nil
        case .openrouter: return "Pay-as-you-go with many model options"
        case .revai: return "Free tier includes 5 hours"
        case .meta: return "Muse Voice Transcribe is billed by audio minute"
        }
    }

    var keychainIdentifier: String { "\(rawValue).apiKey" }

    /// Onboarding sets the key up for transcription; an OpenRouter key also
    /// serves post-processing.
    var guideUses: APIKeyUses {
        self == .openrouter ? [.transcription, .postProcessing] : .transcription
    }

    /// The live streaming transcription model this provider maps to, if any.
    /// Selecting such a provider during onboarding switches the app to remote
    /// streaming so the freshly-added key is used immediately.
    var defaultLiveTranscriptionModel: String? {
        switch self {
        case .deepgram: return "deepgram/nova-3-streaming"
        case .soniox: return "soniox/stt-rt-v6-streaming"
        case .openai, .openrouter, .revai: return nil
        case .meta: return MetaMuseVoiceTranscribe.liveCatalogID
        }
    }

    /// Short label used in the segmented onboarding picker where horizontal
    /// space is tight; `displayName` is used everywhere else.
    var pickerLabel: String {
        switch self {
        case .deepgram: return "Deepgram"
        case .soniox: return "Soniox"
        case .openai: return "OpenAI"
        case .meta: return "Meta"
        case .openrouter: return "OpenRouter"
        case .revai: return "Rev.ai"
        }
    }
}
