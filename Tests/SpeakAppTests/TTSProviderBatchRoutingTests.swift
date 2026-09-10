import Foundation
import XCTest

@testable import SpeakApp
@testable import SpeakCore

/// Covers the mapping layer for the four providers added in September 2026:
/// credential sharing, voice-identifier routing, picker parity, the platform
/// restriction, and how each transport error reaches the user.
final class TTSProviderBatchRoutingTests: XCTestCase {
  // MARK: - Credentials

  func testEachProvider_reusesItsTranscriptionCredential() {
    let expected: [TTSProvider: String] = [
      .groq: "groq.apiKey",
      .gemini: "google.apiKey",
      .mistral: "mistral.apiKey",
      .speechmatics: "speechmatics.apiKey"
    ]
    for (provider, identifier) in expected {
      XCTAssertEqual(provider.apiKeyIdentifier, identifier)
      XCTAssertTrue(provider.requiresAPIKey)
      // One account key covers both directions, so Settings shows one combined
      // card rather than a second entry writing the same Keychain item.
      XCTAssertTrue(provider.sharesTranscriptionCredential)
      XCTAssertTrue(
        ModelCredentialResolver.allKnownAPIKeyIdentifiers.contains(identifier),
        "\(identifier) must stay in the credential-transfer parity set"
      )
    }
  }

  func testGeminiProvider_keepsTheGoogleIdentityItsTranscriptionSideUses() {
    // The raw value is what pairs the voice-output card with the transcription
    // provider of the same id, so it has to stay `google`.
    XCTAssertEqual(TTSProvider.gemini.rawValue, "google")
    XCTAssertEqual(TTSProvider.gemini.displayName, GeminiTranscribeModels.providerDisplayName)
  }

  // MARK: - Voice routing

  func testVoiceIdentifiers_routeBackToTheProviderThatOwnsThem() {
    XCTAssertEqual(TTSProvider.from(voiceID: "groq/orpheus-v1-english/austin"), .groq)
    XCTAssertEqual(TTSProvider.from(voiceID: "google/Kore"), .gemini)
    XCTAssertEqual(TTSProvider.from(voiceID: "mistral/abc-123"), .mistral)
    XCTAssertEqual(TTSProvider.from(voiceID: "speechmatics/theo"), .speechmatics)
    // An unrecognised identifier still falls back to the built-in voices.
    XCTAssertEqual(TTSProvider.from(voiceID: "nonsense"), .system)
  }

  func testPickerCatalogue_matchesTheCanonicalSpeakCoreLists() {
    XCTAssertEqual(
      VoiceCatalog.voices(for: .groq).map(\.id),
      GroqTTSCatalog.voices.map(\.providerVoiceID)
    )
    XCTAssertEqual(
      VoiceCatalog.voices(for: .gemini).map(\.id),
      GeminiTTSCatalog.voices.map(\.providerVoiceID)
    )
    XCTAssertEqual(
      VoiceCatalog.voices(for: .speechmatics).map(\.id),
      SpeechmaticsTTSCatalog.voices.map(\.providerVoiceID)
    )
    // Mistral publishes no preset identifiers, so there is nothing to show
    // until the account's own listing is fetched.
    XCTAssertTrue(VoiceCatalog.voices(for: .mistral).isEmpty)

    for provider in [TTSProvider.groq, .gemini, .speechmatics] {
      for voice in VoiceCatalog.voices(for: provider) {
        XCTAssertEqual(VoiceCatalog.voice(forID: voice.id)?.provider, provider)
      }
    }
  }

  func testEveryNewVoice_reachesTheCombinedCatalogueExactlyOnce() {
    let ids = VoiceCatalog.allVoices.map(\.id)
    XCTAssertEqual(Set(ids).count, ids.count, "voice identifiers must be unique")
    for voice in VoiceCatalog.groqVoices + VoiceCatalog.geminiVoices
      + VoiceCatalog.speechmaticsVoices {
      XCTAssertTrue(ids.contains(voice.id))
    }
  }

  // MARK: - Platform restriction

  func testTheNewProviders_areMacOnly() {
    // Voice output on iOS runs through `VoiceOutputProvider`, which these four
    // are deliberately not part of. This asserts the restriction so it cannot
    // drift silently; see Docs/tts-providers-2026-09.md.
    let iOSProviderIDs = Set(VoiceOutputProvider.allCases.map(\.id))
    for provider in [TTSProvider.groq, .gemini, .mistral, .speechmatics] {
      XCTAssertFalse(iOSProviderIDs.contains(provider.id))
    }
  }

  func testNoneOfTheNewProviders_claimsSSMLPhonemeSupport() {
    for provider in [TTSProvider.groq, .gemini, .mistral, .speechmatics] {
      XCTAssertFalse(provider.supportsSSMLPhonemes)
    }
  }

  // MARK: - Cost estimates

  func testGroqEstimate_followsTheModelTheVoiceNames() {
    let english = TTSProvider.groq.estimatedCost(
      characterCount: 1000,
      quality: .high,
      voiceID: "groq/orpheus-v1-english/austin"
    )
    let arabic = TTSProvider.groq.estimatedCost(
      characterCount: 1000,
      quality: .high,
      voiceID: "groq/orpheus-arabic-saudi/lulwa"
    )
    XCTAssertEqual(english, Decimal(string: "0.022"))
    XCTAssertEqual(arabic, Decimal(string: "0.040"))
  }

  func testGeminiEstimate_isWithheldBecauseBillingIsPerGeneratedToken() {
    // A character estimate would be a guess: Gemini bills the audio it
    // produces, so the real figure is only known after synthesis.
    XCTAssertNil(
      TTSProvider.gemini.estimatedCost(
        characterCount: 1000,
        quality: .high,
        voiceID: "google/Kore"
      )
    )
  }

  func testMistralAndSpeechmaticsEstimates_useThePublishedCharacterRates() {
    XCTAssertEqual(
      TTSProvider.mistral.estimatedCost(characterCount: 1000, quality: .high),
      Decimal(string: "0.016")
    )
    XCTAssertEqual(
      TTSProvider.speechmatics.estimatedCost(characterCount: 1000, quality: .high),
      Decimal(string: "0.011")
    )
  }

  // MARK: - Error mapping

  func testGroqTermsGate_isReportedAsAnAccessRequirementNotABadKey() throws {
    let error = GroqTTSClient.ttsError(
      for: .modelTermsRequired(message: "The model requires terms acceptance.")
    )
    guard case .providerAccessRequired(let provider, let reason) = error else {
      return XCTFail("expected an access requirement, got \(error)")
    }
    XCTAssertEqual(provider, .groq)
    XCTAssertTrue(reason.contains(GroqTTSAPI.modelTermsURL))

    // A rejected key is the one case that should send the user to Settings.
    guard case .apiKeyMissing(.groq) = GroqTTSClient.ttsError(
      for: .unauthorized(statusCode: 401, message: "Invalid API Key")
    ) else {
      return XCTFail("a 401 must be reported as a missing key")
    }
  }

  func testMistralForbidden_namesBothCausesBecauseTheResponseCannotSeparateThem() throws {
    let error = MistralTTSClient.ttsError(for: .forbidden(message: "Forbidden."))
    guard case .providerAccessRequired(.mistral, let reason) = error else {
      return XCTFail("expected an access requirement, got \(error)")
    }
    XCTAssertTrue(reason.lowercased().contains("plan"))
    XCTAssertTrue(reason.lowercased().contains("moderation"))
  }

  func testAuthAndQuotaFailures_mapConsistentlyAcrossTheFourProviders() throws {
    guard case .apiKeyMissing(.gemini) = GeminiTTSClient.ttsError(
      for: .unauthorized(statusCode: 401, message: "invalid key")
    ) else { return XCTFail("Gemini 401 must be a missing key") }

    guard case .apiKeyMissing(.speechmatics) = SpeechmaticsTTSClient.ttsError(
      for: .unauthorized(statusCode: 401, message: "")
    ) else { return XCTFail("Speechmatics 401 must be a missing key") }

    guard case .apiKeyMissing(.mistral) = MistralTTSClient.ttsError(
      for: .unauthorized(statusCode: 401, message: "")
    ) else { return XCTFail("Mistral 401 must be a missing key") }

    let quota = try synthesisFailureMessage(
      SpeechmaticsTTSClient.ttsError(for: .quotaExceeded(message: "no credit"))
    )
    XCTAssertTrue(quota.contains("credit exhausted"))

    let limited = try synthesisFailureMessage(
      GeminiTTSClient.ttsError(for: .rateLimited(message: "daily quota"))
    )
    XCTAssertTrue(limited.contains("quota reached"))
  }

  func testEmptyTextAndMissingVoice_produceActionableMessages() throws {
    let empty = try synthesisFailureMessage(GroqTTSClient.ttsError(for: .emptyText))
    XCTAssertEqual(empty, "There is no text to speak")

    guard case .invalidVoice(let message) = MistralTTSClient.ttsError(for: .voiceRequired) else {
      return XCTFail("a missing voice must be reported as an invalid voice")
    }
    XCTAssertTrue(message.contains("Mistral"))
  }

  // MARK: - Ignored settings

  func testANonDefaultSpeedOrPitch_isReportedRatherThanSilentlyDropped() throws {
    let neutral = TTSSettings()
    XCTAssertNil(GroqTTSClient.unsupportedSettingsMessage(neutral))
    XCTAssertNil(GeminiTTSClient.unsupportedSettingsMessage(neutral))
    XCTAssertNil(MistralTTSClient.unsupportedSettingsMessage(neutral))
    XCTAssertNil(SpeechmaticsTTSClient.unsupportedSettingsMessage(neutral))

    let fast = TTSSettings(speed: 1.4, pitch: 2.0)
    for message in [
      GroqTTSClient.unsupportedSettingsMessage(fast),
      GeminiTTSClient.unsupportedSettingsMessage(fast),
      MistralTTSClient.unsupportedSettingsMessage(fast),
      SpeechmaticsTTSClient.unsupportedSettingsMessage(fast)
    ] {
      let text = try XCTUnwrap(message)
      XCTAssertTrue(text.contains("speed"))
      XCTAssertTrue(text.contains("pitch"))
    }
  }

  func testSpeechmaticsLanguage_rejectsAnExplicitNonEnglishChoice() throws {
    // Automatic and English are honoured; the request carries no language
    // field, so anything else would be dropped in silence.
    XCTAssertNil(
      SpeechmaticsTTSClient.unsupportedSettingsMessage(TTSSettings(language: "automatic"))
    )
    XCTAssertNil(
      SpeechmaticsTTSClient.unsupportedSettingsMessage(TTSSettings(language: "en_GB"))
    )
    let french = try XCTUnwrap(
      SpeechmaticsTTSClient.unsupportedSettingsMessage(TTSSettings(language: "fr_FR"))
    )
    XCTAssertTrue(french.lowercased().contains("english"))
  }

  func testGroqSynthesis_boundsTheNumberOfBillableRequestsOneCallCanFanOutInto() throws {
    XCTAssertEqual(
      GroqTTSAPI.maxSynthesisCharacters,
      GroqTTSAPI.maxInputCharacters * GroqTTSAPI.maxRequestsPerSynthesis
    )
    XCTAssertNil(
      GroqTTSClient.excessiveFanOutMessage(segmentCount: GroqTTSAPI.maxRequestsPerSynthesis)
    )
    // A paste long enough to exceed the budget is refused, not billed.
    let overLong = String(repeating: "word ", count: GroqTTSAPI.maxSynthesisCharacters)
    let segments = TTSTextChunker.chunks(overLong, maximumCharacters: GroqTTSAPI.maxInputCharacters)
    XCTAssertGreaterThan(segments.count, GroqTTSAPI.maxRequestsPerSynthesis)
    let refusal = try XCTUnwrap(GroqTTSClient.excessiveFanOutMessage(segmentCount: segments.count))
    XCTAssertTrue(refusal.contains("\(GroqTTSAPI.maxSynthesisCharacters)"))
  }

  func testKnownVoiceIDPrefixes_coverEveryProviderTheRouterDispatches() {
    for prefix in TTSProvider.knownVoiceIDPrefixes where prefix != "system/" {
      XCTAssertNotEqual(
        TTSProvider.from(voiceID: prefix + "sample"),
        .system,
        "\(prefix) must route to its own provider"
      )
    }
    // The account-listed Mistral case is the one this list exists for.
    XCTAssertTrue(
      TTSProvider.knownVoiceIDPrefixes.contains(MistralTTSCatalog.voiceIDPrefix)
    )
    XCTAssertEqual(TTSProvider.from(voiceID: "mistral/some-cloned-voice"), .mistral)
  }

  func testAccountListedVoice_keepsAStoredMistralSelectionInThePicker() throws {
    let voice = try XCTUnwrap(VoiceCatalog.voice(forID: "mistral/abc123"))
    XCTAssertEqual(voice.provider, .mistral)
    XCTAssertEqual(
      VoiceCatalog.includingSelection("mistral/abc123", in: []).map(\.id),
      ["mistral/abc123"]
    )
  }

  func testMistralFormatMapping_servesAnM4APreferenceAsMP3() {
    XCTAssertEqual(MistralTTSClient.effectiveFormat(for: .m4a), .mp3)
    XCTAssertEqual(MistralTTSClient.responseFormat(for: .m4a), .mp3)
    XCTAssertEqual(MistralTTSClient.responseFormat(for: .wav), .wav)
  }

  // MARK: - Helpers

  private struct UnexpectedTTSError: Error, CustomStringConvertible {
    let description: String
  }

  private func synthesisFailureMessage(_ error: TTSError) throws -> String {
    guard case .synthesisFailure(let message) = error else {
      // A wrong error case is a routing defect, not a reason to skip.
      XCTFail("expected a synthesis failure, got \(error)")
      throw UnexpectedTTSError(description: "expected a synthesis failure, got \(error)")
    }
    return message
  }
}
