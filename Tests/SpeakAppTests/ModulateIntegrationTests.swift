import Foundation
import XCTest

@testable import SpeakApp

final class ModulateIntegrationTests: XCTestCase {
  func testFeatureConfigurationBuildsExpectedQueryItems() {
    let configuration = ModulateFeatureConfiguration(
      speakerDiarization: true,
      emotionSignal: true,
      accentSignal: false,
      piiPhiTagging: true
    )

    let query: [String: String] = Dictionary(
      uniqueKeysWithValues: configuration.queryItems.compactMap { item in
        guard let value = item.value else { return nil }
        return (item.name, value)
      }
    )

    XCTAssertEqual(query["speaker_diarization"], "true")
    XCTAssertEqual(query["emotion_signal"], "true")
    XCTAssertEqual(query["accent_signal"], "false")
    XCTAssertEqual(query["pii_phi_tagging"], "true")
  }

  func testFeatureConfigurationReadsPersistedDefaults() {
    let suiteName = "ModulateIntegrationTests-\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      XCTFail("Failed to create isolated defaults suite")
      return
    }
    defer {
      defaults.removePersistentDomain(forName: suiteName)
    }

    defaults.set(false, forKey: AppSettings.DefaultsKey.modulateSpeakerDiarization.rawValue)
    defaults.set(true, forKey: AppSettings.DefaultsKey.modulateEmotionSignal.rawValue)
    defaults.set(true, forKey: AppSettings.DefaultsKey.modulateAccentSignal.rawValue)
    defaults.set(false, forKey: AppSettings.DefaultsKey.modulatePIIPhiTagging.rawValue)

    let configuration = ModulateFeatureConfiguration(defaults: defaults)

    XCTAssertFalse(configuration.speakerDiarization)
    XCTAssertTrue(configuration.emotionSignal)
    XCTAssertTrue(configuration.accentSignal)
    XCTAssertFalse(configuration.piiPhiTagging)
  }

  func testFormattedTranscriptAddsSpeakerLabelsWhenMultipleSpeakersPresent() {
    let configuration = ModulateFeatureConfiguration(
      speakerDiarization: true,
      emotionSignal: false,
      accentSignal: false,
      piiPhiTagging: false
    )
    let utterances = [
      ModulateUtterance(
        utteranceUUID: UUID(),
        text: "Hello there",
        startMs: 0,
        durationMs: 800,
        speaker: 1,
        language: "en",
        emotion: nil,
        accent: nil
      ),
      ModulateUtterance(
        utteranceUUID: UUID(),
        text: "Hi!",
        startMs: 900,
        durationMs: 500,
        speaker: 2,
        language: "en",
        emotion: nil,
        accent: nil
      )
    ]

    let transcript = configuration.formattedTranscript(from: utterances, fallbackText: "Hello there Hi!")

    XCTAssertEqual(transcript, "Speaker 1: Hello there\nSpeaker 2: Hi!")
  }

  func testTranscriptionProviderRegistryIncludesModulate() async {
    let registry = TranscriptionProviderRegistry.shared

    let provider = await registry.provider(withID: "modulate")

    XCTAssertNotNil(provider)
    XCTAssertEqual(provider?.metadata.apiKeyIdentifier, "modulate.apiKey")
  }
}
