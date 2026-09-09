import Foundation
import XCTest

@testable import SpeakApp
import SpeakCore

/// The mapping layer for xAI speech: which picker each option appears in, that
/// one Keychain entry serves all three directions, that the voice identifiers
/// route home, and how the progressive path is chosen.
final class XAISpeechRoutingTests: XCTestCase {

  // MARK: - Transcription pickers

  func testProviderRegistry_ownsBothTheStreamingAndTheBatchIdentifier() async {
    for model in [XAIVoiceModels.thinkFast2CatalogID, XAISpeechToText.batchCatalogID,
                  XAISpeechToText.liveCatalogID] {
      let provider = await TranscriptionProviderRegistry.shared.provider(forModel: model)
      XCTAssertEqual(provider?.metadata.id, "xai", "\(model) must route to the xAI provider")
      XCTAssertEqual(provider?.metadata.apiKeyIdentifier, "xai.apiKey")
    }
  }

  func testSupportedModels_listExactlyTheCatalogueEntriesXAIOwns() async {
    let provider = await TranscriptionProviderRegistry.shared.provider(withID: "xai")
    XCTAssertEqual(
      provider?.supportedModels().map(\.id),
      [
        XAIVoiceModels.thinkFast2CatalogID,
        XAISpeechToText.liveCatalogID,
        XAISpeechToText.batchCatalogID
      ]
    )
    // An identifier xAI does not own must not be claimed by it, so a future
    // `xai/` model cannot silently take the batch route of another service.
    let unknown = await TranscriptionProviderRegistry.shared.provider(forModel: "xai/not-a-model")
    XCTAssertNil(unknown)
  }

  /// Grok Voice has no file mode, so selecting it for a recording has to say so
  /// rather than uploading to an endpoint that would reject it.
  func testFileTranscription_refusesTheStreamingOnlyGrokVoiceModel() async {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(UUID().uuidString).wav")
    do {
      _ = try await XAITranscriptionProvider().transcribeFile(
        at: url,
        apiKey: "fixture",
        model: XAIVoiceModels.thinkFast2CatalogID,
        language: nil
      )
      XCTFail("expected the streaming-only model to be refused")
    } catch {
      let message = error.localizedDescription
      XCTAssertTrue(message.contains("no file"), message)
      XCTAssertTrue(message.contains("xAI Speech-to-Text"), message)
    }
  }

  // MARK: - Voice output

  func testVoiceOutput_reusesTheTranscriptionCredentialRatherThanAddingOne() {
    XCTAssertEqual(TTSProvider.xai.apiKeyIdentifier, "xai.apiKey")
    XCTAssertTrue(TTSProvider.xai.requiresAPIKey)
    // One account key covers Grok Voice, speech to text and speech generation,
    // so Settings shows one combined card instead of a second entry writing
    // the same Keychain item.
    XCTAssertTrue(TTSProvider.xai.sharesTranscriptionCredential)
    XCTAssertTrue(ModelCredentialResolver.allKnownAPIKeyIdentifiers.contains("xai.apiKey"))
    XCTAssertEqual(
      ModelCredentialResolver.requirement(for: "xai/eve", purpose: .voiceOutput),
      .apiKey(identifier: "xai.apiKey", providerName: "xAI")
    )
  }

  func testVoiceIdentifiers_routeBackToXAIIncludingAccountVoices() {
    XCTAssertEqual(TTSProvider.from(voiceID: "xai/eve"), .xai)
    XCTAssertEqual(TTSProvider.from(voiceID: "xai/nlbqfwie"), .xai)
    XCTAssertEqual(TTSProvider.from(voiceID: "nonsense"), .system)
  }

  func testPickerCatalogue_matchesTheCanonicalSpeakCoreList() {
    XCTAssertEqual(
      VoiceCatalog.voices(for: .xai).map(\.id),
      XAITTSCatalog.voices.map(\.providerVoiceID)
    )
    for voice in VoiceCatalog.xaiVoices {
      XCTAssertEqual(VoiceCatalog.voice(forID: voice.id)?.provider, .xai)
      XCTAssertTrue(VoiceCatalog.allVoices.map(\.id).contains(voice.id))
    }
    let ids = VoiceCatalog.allVoices.map(\.id)
    XCTAssertEqual(Set(ids).count, ids.count, "voice identifiers must be unique")
  }

  func testVoiceOutput_isMacOnlyLikeEveryOtherEntryInTextToSpeech() {
    // iOS voice output runs through `VoiceOutputProvider`, which xAI is
    // deliberately not part of in this change; see Docs/tts-providers-2026-09.md.
    XCTAssertFalse(Set(VoiceOutputProvider.allCases.map(\.id)).contains(TTSProvider.xai.id))
    XCTAssertFalse(TTSProvider.xai.supportsSSMLPhonemes)
  }

  func testCostEstimate_usesThePublishedCharacterRate() {
    XCTAssertEqual(
      TTSProvider.xai.estimatedCost(characterCount: 1000, quality: .high, voiceID: "xai/eve"),
      Decimal(string: "0.015")
    )
  }

  // MARK: - Progressive playback

  func testOnlyXAI_optsIntoTheProgressivePlaybackPath() {
    // The manager takes the streaming path only for a client that conforms, so
    // conformance is the switch: xAI has it, and a provider with no streaming
    // route keeps the synthesize-then-play behaviour untouched.
    XCTAssertTrue(XAITTSClient.self is any ProgressiveTextToSpeechClient.Type)
    XCTAssertFalse(SystemTTSClient.self is any ProgressiveTextToSpeechClient.Type)
    XCTAssertFalse(SpeechmaticsTTSClient.self is any ProgressiveTextToSpeechClient.Type)
    XCTAssertFalse(GroqTTSClient.self is any ProgressiveTextToSpeechClient.Type)
  }

  func testIgnoredSettings_areReportedRatherThanSilentlyDropped() {
    // xAI documents no pitch parameter, and a rate outside 0.7–1.5 would be
    // clamped into a speed the user did not choose.
    XCTAssertThrowsError(
      try XAITTSClient.validate(settings: TTSSettings(pitch: 0.5))
    ) { error in
      XCTAssertTrue(error.localizedDescription.contains("pitch"), error.localizedDescription)
    }
    XCTAssertThrowsError(
      try XAITTSClient.validate(settings: TTSSettings(speed: 2.0))
    ) { error in
      XCTAssertTrue(error.localizedDescription.contains("speaking rate"), error.localizedDescription)
    }
    XCTAssertNoThrow(try XAITTSClient.validate(settings: TTSSettings(speed: 1.2)))
  }

  /// AAC is not one of the codecs xAI serves, so an M4A preference has to land
  /// on a container it does serve rather than producing an unplayable file.
  func testOutputFormat_mapsThePreferenceOntoACodecXAIServes() {
    XCTAssertEqual(XAITTSClient.codec(for: .mp3), .mp3)
    XCTAssertEqual(XAITTSClient.codec(for: .wav), .wav)
    XCTAssertEqual(XAITTSClient.codec(for: .m4a), .mp3)
    XCTAssertEqual(XAITTSClient.audioFormat(for: .pcm), .wav)
  }

  func testTransportErrors_reachTheUserAsTheRightKindOfFailure() {
    // A revoked key sends the user to Settings; an empty balance does not,
    // because a stored key was never evidence of credit.
    XCTAssertEqual(
      XAITTSClient.ttsError(for: .unauthorized(statusCode: 401, message: "nope"))
        .localizedDescription,
      TTSError.apiKeyMissing(.xai).localizedDescription
    )
    let quota = XAITTSClient.ttsError(for: .quotaExceeded(message: "empty")).localizedDescription
    XCTAssertTrue(quota.contains("console.x.ai"), quota)
    let voice = XAITTSClient.ttsError(for: .voiceNotFound(message: "no such voice"))
      .localizedDescription
    XCTAssertTrue(voice.contains("Invalid voice"), voice)
    XCTAssertEqual(
      XAITTSClient.ttsError(for: .emptyText).localizedDescription,
      TTSError.synthesisFailure("There is no text to speak").localizedDescription
    )
  }
}
