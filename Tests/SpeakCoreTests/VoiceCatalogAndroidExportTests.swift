import Foundation
import XCTest

@testable import SpeakCore

/// The Android app's cloud voices are a committed JSON asset; this keeps it identical to SpeakCore.
final class VoiceCatalogAndroidExportTests: XCTestCase {
    private var assetURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("android/app/src/main/assets/voice_catalog.json")
    }

    func testAndroidAssetMatchesCatalogue() throws {
        let expected = try VoiceCatalogAndroidExport.json()
        if ProcessInfo.processInfo.environment["UPDATE_VOICE_CATALOG_ANDROID"] == "1" {
            try expected.write(to: assetURL)
        }
        let committed = try Data(contentsOf: assetURL)
        XCTAssertEqual(
            committed, expected,
            "android/app/src/main/assets/voice_catalog.json is stale. Regenerate with "
                + "UPDATE_VOICE_CATALOG_ANDROID=1 swift test --filter VoiceCatalogAndroidExportTests"
        )
    }

    func testEveryCurrentFixedVoiceOfAnAndroidProviderIsExported() throws {
        let voices = try VoiceCatalogAndroidExport.voices()
        let expected = DesktopSpeechVoice.voices.filter { VoiceCatalogAndroidExport.provider(of: $0) != nil }
        XCTAssertEqual(voices.map(\.key), expected.map { "\($0.modelID)|\($0.id)" })
        XCTAssertEqual(Set(voices.map(\.key)).count, voices.count, "voice keys must be unique")
        XCTAssertEqual(
            Set(voices.map(\.provider)),
            ["deepgram", "azure", "xai", "cartesia", "soniox", "google", "groq", "speechmatics", "elevenlabs"]
        )
        for voice in voices {
            XCTAssertNil(ModelRetirements.retirement(for: voice.modelID), voice.key)
        }
    }

    func testVoicesUseCredentialsAndroidAlreadyStores() throws {
        let stored = Set(CloudCatalogAndroidExport.providerCredentialIdentifiers)
        for voice in try VoiceCatalogAndroidExport.voices() {
            XCTAssertTrue(stored.contains(voice.credentialID), "\(voice.key): \(voice.credentialID)")
        }
    }

    func testTemplatesCarryPlaceholdersAndNoTokens() throws {
        let data = try VoiceCatalogAndroidExport.json()
        let text = try XCTUnwrap(String(bytes: data, encoding: .utf8))
        for token in [
            VoiceCatalogAndroidExport.textToken, VoiceCatalogAndroidExport.keyToken,
            VoiceCatalogAndroidExport.regionToken
        ] {
            XCTAssertFalse(text.contains(token), token)
        }
        for voice in try VoiceCatalogAndroidExport.voices() {
            let encoded = try XCTUnwrap(String(bytes: JSONEncoder().encode(voice.request), encoding: .utf8))
            XCTAssertTrue(encoded.contains("{text}"), voice.key)
            XCTAssertTrue(encoded.contains("{key}"), voice.key)
            XCTAssertEqual(voice.request.xmlBody != nil, voice.provider == "azure", voice.key)
            if voice.provider == "azure" {
                XCTAssertTrue(voice.request.url.contains("{region}"), voice.key)
            }
            if ["cartesia", "soniox"].contains(voice.provider) {
                XCTAssertTrue(encoded.contains("{language}"), voice.key)
            }
        }
    }

    func testDialogueOnlyElevenLabsModelsFallBackToTheSharedFallbackModel() throws {
        let voices = try VoiceCatalogAndroidExport.voices().filter { $0.provider == "elevenlabs" }
        let dialogue = voices.filter { $0.dialogue != nil }
        XCTAssertFalse(dialogue.isEmpty)
        for voice in dialogue {
            let modelID = voice.modelID.replacingOccurrences(of: "elevenlabs/", with: "")
            XCTAssertTrue(ElevenLabsTTSModels.dialogueOnlyModelIDs.contains(modelID), voice.key)
            XCTAssertEqual(voice.dialogue?.maxCharacters, ElevenLabsTTSModels.dialogueCharacterLimit)
            XCTAssertEqual(voice.maxCharacters, ElevenLabsTTSModels.dialogueFallback.maximumCharacters)
            let fallback = try XCTUnwrap(String(bytes: JSONEncoder().encode(voice.request), encoding: .utf8))
            XCTAssertTrue(fallback.contains(ElevenLabsTTSModels.dialogueFallback.id), voice.key)
        }
    }

    func testPronunciationDefaultsMatchTheSharedDefaults() {
        let defaults = PronunciationEntry.defaultEntries
        let exported = VoiceCatalogAndroidExport.pronunciationDefaults
        XCTAssertEqual(exported.map(\.word), defaults.map(\.word))
        XCTAssertEqual(exported.map(\.replacement), defaults.map(\.replacement))
    }
}
