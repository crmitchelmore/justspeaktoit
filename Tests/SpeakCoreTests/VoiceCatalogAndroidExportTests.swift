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
            VoiceCatalogAndroidExport.regionToken, VoiceCatalogAndroidExport.voiceToken,
            VoiceCatalogAndroidExport.voiceToken.lowercased(), VoiceCatalogAndroidExport.nameToken
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

    func testAccountProvidersListAndSpeakWithTheSavedKey() throws {
        let accounts = try VoiceCatalogAndroidExport.accountProviders()
        XCTAssertEqual(accounts.map(\.provider), ["mistral", "xai", "soniox"])
        XCTAssertEqual(Set(accounts.map(\.provider)), Set(VoiceAccountProvider.all.map(\.id)))
        let stored = Set(CloudCatalogAndroidExport.providerCredentialIdentifiers)
        for account in accounts {
            XCTAssertTrue(stored.contains(account.credentialID), account.provider)
            XCTAssertNil(ModelRetirements.retirement(for: account.modelID), account.provider)
            XCTAssertTrue(account.keyTemplate.hasPrefix("\(account.modelID)|"), account.provider)
            XCTAssertTrue(account.keyTemplate.hasSuffix(account.idTemplate), account.provider)
            XCTAssertTrue(account.idTemplate.contains("{voice}"), account.provider)
            XCTAssertTrue(account.labelTemplate.contains("{name}"), account.provider)
            XCTAssertTrue(account.list.headers.values.contains { $0.contains("{key}") }, account.provider)
            XCTAssertEqual(account.list.method, "GET", account.provider)
            let request = try XCTUnwrap(String(bytes: JSONEncoder().encode(account.request), encoding: .utf8))
            for placeholder in ["{text}", "{key}", "{voice}"] {
                XCTAssertTrue(request.contains(placeholder), "\(account.provider) \(placeholder)")
            }
        }
        XCTAssertEqual(accounts.map(\.lowercaseVoiceID), [false, true, false])
        XCTAssertEqual(accounts.first { $0.provider == "mistral" }?.response, "base64Wav")
        XCTAssertEqual(accounts.first { $0.provider == "soniox" }?.readyModel, SonioxTTSModel.realtimeV2.rawValue)
    }

    /// Android adds the page parameter to the exported first-page URL; it must equal the builder's own.
    func testLaterPageURLsMatchTheSharedBuilders() throws {
        let accounts = try VoiceCatalogAndroidExport.accountProviders()
        let mistral = try XCTUnwrap(accounts.first { $0.provider == "mistral" })
        let mistralPage = try MistralTTSAPI.voiceListRequest(apiKey: "k", offset: MistralTTSAPI.voicePageSize)
        XCTAssertEqual(mistral.list.pageParameter, "offset")
        XCTAssertEqual(
            mistralPage.url?.absoluteString, "\(mistral.list.url)&offset=\(MistralTTSAPI.voicePageSize)"
        )
        let soniox = try XCTUnwrap(accounts.first { $0.provider == "soniox" })
        let sonioxPage = try SonioxTTSAPI.voiceListRequest(apiKey: "k", region: .unitedStates, cursor: "abc_123")
        XCTAssertEqual(soniox.list.pageParameter, "cursor")
        XCTAssertEqual(sonioxPage.url?.absoluteString, "\(soniox.list.url)&cursor=abc_123")
        let xai = try XCTUnwrap(accounts.first { $0.provider == "xai" })
        XCTAssertNil(xai.list.pageParameter)
        XCTAssertEqual(xai.list.url, XAITTSAPI.voiceListRequest(apiKey: "k").url?.absoluteString)
    }

    func testRealtimeVoicesMatchTheSharedRealtimeSpeech() throws {
        let realtime = try VoiceCatalogAndroidExport.realtime()
        XCTAssertEqual(realtime.voices.map(\.voice), OpenAIRealtimeSpeech.voices.map(\.id))
        XCTAssertEqual(
            realtime.voices.map(\.key),
            OpenAIRealtimeSpeech.voices.map { voice in
                let desktop = DesktopSpeechVoice.openaiRealtime(voice.id)
                return "\(desktop.modelID)|\(desktop.id)"
            }
        )
        XCTAssertNil(ModelRetirements.retirement(for: realtime.modelID))
        XCTAssertTrue(Set(CloudCatalogAndroidExport.providerCredentialIdentifiers).contains(realtime.credentialID))
        XCTAssertTrue(realtime.url.hasPrefix("wss://"))
        XCTAssertTrue(realtime.headers.values.contains { $0.contains("{key}") })
        let session = try XCTUnwrap(String(bytes: JSONEncoder().encode(realtime.sessionUpdate), encoding: .utf8))
        let response = try XCTUnwrap(String(bytes: JSONEncoder().encode(realtime.responseCreate), encoding: .utf8))
        XCTAssertTrue(session.contains("{voice}"))
        XCTAssertTrue(response.contains("{text}"))
    }
}
