import Foundation
import SpeakCore

/// Voice discovery for `TextToSpeechManager`.
///
/// Kept beside the manager rather than inside it: listing voices is a separate
/// concern from synthesising and playing them, and some providers — Mistral
/// above all — have no offline catalogue, so this is where a runtime listing
/// and its failures are reconciled with the static one.
/// What the last runtime voice listing produced.
struct TTSVoiceListingState {
  /// Last listing each provider served, kept so a later outage falls back to
  /// the voices the user could pick a moment ago instead of to nothing.
  var lastKnown: [TTSProvider: [TTSVoice]] = [:]
  /// Providers whose listing failed on that load, with the reason.
  var failures: [TTSProvider: String] = [:]
}

extension TextToSpeechManager {
  /// Providers whose runtime voice listing failed on the last load.
  var voiceListingErrors: [TTSProvider: String] { voiceListing.failures }

  func availableVoices() async -> [TTSVoice] {
    var voices: [TTSVoice] = []
    var failures: [TTSProvider: String] = [:]

    for (provider, client) in clients {
      guard await hasAPIKey(for: provider) || !provider.requiresAPIKey else { continue }
      do {
        let providerVoices = try await client.listVoices()
        voiceListing.lastKnown[provider] = providerVoices
        voices.append(contentsOf: providerVoices)
      } catch {
        // A listing outage must stay visible and retryable. Falling back to
        // the last good listing keeps a keyed provider usable meanwhile.
        failures[provider] = error.localizedDescription
        voices.append(contentsOf: voiceListing.lastKnown[provider] ?? [])
      }
    }

    voiceListing.failures = failures
    return voices.isEmpty ? VoiceCatalog.systemVoices : voices
  }

  /// Voices a keyed account offers that no offline catalogue lists.
  ///
  /// Mistral publishes no preset voices at all, so its entire list is runtime
  /// only. Settings merges these into the Default Voice picker; without them
  /// an account voice could be chosen in Voice Output but never set as the
  /// default.
  func accountListedVoices() async -> [TTSVoice] {
    let catalogued = Set(VoiceCatalog.allVoices.map(\.id))
    return await availableVoices().filter { !catalogued.contains($0.id) }
  }
}
