import SpeakCore
import SwiftUI

struct MacAPIKeyItem: Identifiable {
  enum Source {
    case openRouter
    case transcription(TranscriptionProviderMetadata)
    case textToSpeech(TTSProvider)
    /// A native cleanup provider whose key no speech card already manages.
    case postProcessing(NativeTextProvider)
  }

  let entry: APIKeyListEntry
  let source: Source
  var id: String { entry.id }
}

extension MacAPIKeyItem {
  /// Every card the API Keys tab can show, before search, filter and sort.
  @MainActor
  static func all(
    transcriptionProviders: [TranscriptionProviderMetadata],
    form: APIKeyFormModel,
    isStored: (String) -> Bool
  ) -> [MacAPIKeyItem] {
    var items = [
      MacAPIKeyItem(
        entry: APIKeyListEntry(
          id: "general-openrouter",
          title: "OpenRouter",
          category: "Transcription, Voice Output & Post-processing",
          isStored: isStored(APIKeyFormModel.openRouterKeyIdentifier),
          hasError: form.openRouterState.hasFailed
        ),
        source: .openRouter
      )
    ]
    // ElevenLabs, Soniox and Cartesia each use one key for transcription and
    // voice output; their combined card is contributed by the TTS list below.
    let sharedCredentialProviderIDs = Set(
      TTSProvider.allCases.filter(\.sharesTranscriptionCredential).map(\.id)
    )
    items += transcriptionProviders
      .filter { !sharedCredentialProviderIDs.contains($0.id) }
      .map { provider in
        MacAPIKeyItem(
          entry: APIKeyListEntry(
            id: "transcription-\(provider.id)",
            title: provider.displayName,
            category: "Transcription",
            isStored: isStored(provider.apiKeyIdentifier),
            hasError: form.providerStates[provider.id]?.hasFailed ?? false
          ),
          source: .transcription(provider)
        )
      }
    items += TTSProvider.apiKeyCardProviders.map { provider in
      let isShared = provider.sharesTranscriptionCredential
      return MacAPIKeyItem(
        entry: APIKeyListEntry(
          id: "tts-\(provider.id)",
          title: provider == .elevenlabs ? "ElevenLabs" : provider.displayName,
          category: isShared ? "Transcription & Voice Output" : "Voice Output",
          isStored: isStored(provider.apiKeyIdentifier),
          hasError: form.ttsStates[provider.rawValue]?.hasFailed ?? false
        ),
        source: .textToSpeech(provider)
      )
    }
    items += nativeTextItems(coveredBy: transcriptionProviders, isStored: isStored)
    return items
  }

  /// Native cleanup providers whose key no transcription or voice-output card already manages.
  private static func nativeTextItems(
    coveredBy transcriptionProviders: [TranscriptionProviderMetadata],
    isStored: (String) -> Bool
  ) -> [MacAPIKeyItem] {
    let covered = Set(transcriptionProviders.map(\.apiKeyIdentifier))
      .union(TTSProvider.allCases.map(\.apiKeyIdentifier))
    return NativeTextModels.providers
      .filter { !covered.contains($0.credentialIdentifier) }
      .map { provider in
        MacAPIKeyItem(
          entry: APIKeyListEntry(
            id: "text-\(provider.id)",
            title: provider.displayName,
            category: "Post-processing",
            isStored: isStored(provider.credentialIdentifier)
          ),
          source: .postProcessing(provider)
        )
      }
  }
}

extension TTSProvider {
  /// Voice-output providers with their own API-key card, in display order.
  /// OpenRouter shares the general card; the system voice needs no key.
  static let apiKeyCardProviders: [TTSProvider] = [
    .elevenlabs, .openai, .azure, .deepgram, .soniox, .cartesia,
    .groq, .gemini, .mistral, .speechmatics, .xai
  ]
}

/// How each voice-output provider's API-key card presents itself.
extension TTSProvider {
  var apiKeyCardTint: Color {
    switch self {
    case .elevenlabs: return .brandAccent
    case .openai: return .green
    case .openrouter: return .indigo
    case .azure: return .brandLagoonDeep
    case .deepgram: return .brandAccentWarm
    case .soniox: return .brandLagoon
    case .cartesia: return .purple
    case .groq: return .orange
    case .gemini: return .blue
    case .mistral: return .indigo
    case .speechmatics: return .cyan
    case .xai: return .black
    case .system: return .gray
    }
  }

  var apiKeyCardSystemImage: String {
    switch self {
    case .elevenlabs: return "waveform.circle"
    case .openai: return "brain"
    case .openrouter: return "waveform"
    case .azure: return "cloud"
    case .deepgram: return "bolt.circle"
    case .soniox: return "globe"
    case .cartesia: return "waveform.and.person.filled"
    case .groq: return "bolt.horizontal.circle"
    case .gemini: return "sparkles"
    case .mistral: return "waveform.circle"
    case .speechmatics: return "waveform.and.magnifyingglass"
    case .xai: return "waveform.badge.mic"
    case .system: return "speaker.wave.2"
    }
  }

  var apiKeyWebsite: String {
    switch self {
    case .elevenlabs: return "https://elevenlabs.io"
    case .openai: return "https://platform.openai.com"
    case .openrouter: return "https://openrouter.ai"
    case .azure: return "https://azure.microsoft.com/en-us/services/cognitive-services/text-to-speech/"
    case .deepgram: return "https://deepgram.com"
    case .soniox: return "https://soniox.com"
    case .cartesia: return "https://cartesia.ai"
    case .groq: return "https://console.groq.com"
    case .gemini: return "https://aistudio.google.com/apikey"
    case .mistral: return "https://console.mistral.ai"
    case .speechmatics: return "https://www.speechmatics.com"
    case .xai: return "https://console.x.ai"
    case .system: return ""
    }
  }

  // Soniox and Cartesia each use one account key for transcription and speech
  // generation, so this is the only card for them — the transcription list
  // skips those providers.
  var apiKeyCardDescription: String {
    switch self {
    case .azure:
      return "For direct Azure transcription and voice output, enter key:region. "
        + "For local-proxy transcription, set the resource endpoint above and enter local-proxy/ "
        + "followed by the proxy token. Proxy credentials do not enable voice output."
    case .soniox:
      return "Stored securely in your macOS Keychain. Used for Soniox transcription and for "
        + "Soniox TTS v2 voice output in 60+ languages."
    case .cartesia:
      return "Stored securely in your macOS Keychain. Used for Cartesia Ink transcription and for "
        + "Cartesia Sonic 3.6 voice output."
    case .groq:
      return "Stored securely in your macOS Keychain. Used for Groq Whisper transcription and for "
        + "Orpheus voice output. Orpheus also needs your Groq organisation to accept the model "
        + "terms in the console; a saved key alone does not grant access."
    case .gemini:
      return "Stored securely in your macOS Keychain. Used for Gemini transcription and for "
        + "Gemini voice output, billed directly by Google rather than through OpenRouter."
    case .mistral:
      return "Stored securely in your macOS Keychain. Used for Mistral Voxtral transcription and "
        + "for Voxtral voice output. Mistral publishes no preset voices, so the picker loads the "
        + "voices your account can use once this key is saved."
    case .speechmatics:
      return "Stored securely in your macOS Keychain. Used for Speechmatics transcription and for "
        + "Speechmatics voice output, which the vendor still labels a preview. During that "
        + "preview Speechmatics stores the text you send for voice output and the audio it "
        + "generates, to improve their service."
    default:
      return "Stored securely in your macOS Keychain. Used only for "
        + "\(displayName) text-to-speech voice synthesis."
    }
  }
}
