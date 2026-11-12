import Foundation
import XCTest

@testable import SpeakCore

final class SharedApplicationPreferenceTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "SharedApplicationPreferenceTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private typealias Shared = SharedApplicationPreferences

    /// Keys as both apps wrote them before the metadata was shared.
    func testStorageKeysMatchPreviouslyPersistedNames() {
        XCTAssertEqual(Shared.storageKeys(on: .macOS), [
            "liveTranscriptionModel", "batchTranscriptionModel", "postProcessingModel", "preferredLocale",
            "transcriptionKeywords", "postProcessingEnabled", "handsFreeDictationEnabled", "keepAudioOnCancel",
            "cleanupModelDiscoveryEnabled", "visualDensity",
            "rememberedOnDeviceLiveTranscriptionModel", "rememberedRemoteLiveTranscriptionModel"
        ])
        XCTAssertEqual(Shared.storageKeys(on: .iOS), [
            "selectedModel", "batchTranscriptionModel", "postProcessingModel", "preferredLocale",
            "transcriptionKeywords", "postProcessingEnabled", "handsFreeDictationEnabled", "keepAudioOnCancel",
            "cleanupModelDiscoveryEnabled", "visualDensity",
            "rememberedOnDeviceLiveTranscriptionModel", "rememberedRemoteLiveTranscriptionModel"
        ])
        XCTAssertEqual(Shared.cleanupModelDiscoveryEnabled.macOS.key, CleanupModelSelection.preferenceKey)
    }

    /// Defaults as both apps read them for a missing key before the metadata was shared.
    func testDefaultsMatchPreviousPlatformDefaults() {
        for platform in ApplePreferencePlatform.allCases {
            XCTAssertEqual(Shared.handsFreeDictationEnabled.projection(on: platform).defaultValue, false)
            XCTAssertEqual(Shared.keepAudioOnCancel.projection(on: platform).defaultValue, true)
            XCTAssertEqual(Shared.cleanupModelDiscoveryEnabled.projection(on: platform).defaultValue, false)
            XCTAssertEqual(Shared.visualDensity.projection(on: platform).defaultValue, .normal)
            XCTAssertEqual(Shared.transcriptionKeywords.projection(on: platform).defaultValue, "")
            XCTAssertEqual(Shared.preferredLocale.projection(on: platform).defaultValue, "automatic")
        }
        XCTAssertTrue(Shared.postProcessingEnabled.macOS.defaultValue)
        XCTAssertFalse(Shared.postProcessingEnabled.iOS.defaultValue)

        // Missing keys read exactly what each app's previous expression produced.
        XCTAssertEqual(Shared.liveTranscriptionModel.macOS.value(in: defaults),
                       ModelCatalog.normalizedLiveTranscriptionModel(nil))
        XCTAssertEqual(Shared.liveTranscriptionModel.iOS.value(in: defaults),
                       ModelCatalog.normalizedLiveTranscriptionModel(AppleLocalModels.preferredSpeechModelID))
        for platform in ApplePreferencePlatform.allCases {
            XCTAssertEqual(Shared.batchTranscriptionModel.projection(on: platform).value(in: defaults),
                           ModelCatalog.normalizedBatchTranscriptionModel(nil))
            XCTAssertEqual(Shared.postProcessingModel.projection(on: platform).value(in: defaults),
                           ModelCatalog.normalizedPostProcessingModel(nil))
            XCTAssertEqual(Shared.preferredLocale.projection(on: platform).value(in: defaults), "automatic")
        }
        XCTAssertTrue(Shared.postProcessingEnabled.macOS.value(in: defaults))
        XCTAssertFalse(Shared.postProcessingEnabled.iOS.value(in: defaults))
    }

    /// Values written by an older build load unchanged on both platforms.
    func testOldPreferencesRoundTrip() {
        defaults.set("groq/whisper-large-v3-turbo", forKey: "batchTranscriptionModel")
        defaults.set("anthropic/claude-haiku-5.5", forKey: "postProcessingModel")
        defaults.set("fr_FR", forKey: "preferredLocale")
        defaults.set("Saved words", forKey: "transcriptionKeywords")
        defaults.set("compact", forKey: "visualDensity")
        defaults.set(false, forKey: "postProcessingEnabled")
        defaults.set(true, forKey: "handsFreeDictationEnabled")
        defaults.set(false, forKey: "keepAudioOnCancel")
        defaults.set(true, forKey: "cleanupModelDiscoveryEnabled")
        defaults.set("deepgram/nova-3-streaming", forKey: "liveTranscriptionModel")
        defaults.set("deepgram/nova-3-streaming", forKey: "selectedModel")

        for platform in ApplePreferencePlatform.allCases {
            XCTAssertEqual(Shared.batchTranscriptionModel.projection(on: platform).value(in: defaults),
                           "groq/whisper-large-v3-turbo")
            XCTAssertEqual(Shared.postProcessingModel.projection(on: platform).value(in: defaults),
                           "anthropic/claude-haiku-5.5")
            XCTAssertEqual(Shared.preferredLocale.projection(on: platform).value(in: defaults), "fr_FR")
            XCTAssertEqual(Shared.transcriptionKeywords.projection(on: platform).value(in: defaults), "Saved words")
            XCTAssertEqual(Shared.visualDensity.projection(on: platform).value(in: defaults),
                           .compact)
            XCTAssertFalse(Shared.postProcessingEnabled.projection(on: platform).value(in: defaults))
            XCTAssertTrue(Shared.handsFreeDictationEnabled.projection(on: platform).value(in: defaults))
            XCTAssertFalse(Shared.keepAudioOnCancel.projection(on: platform).value(in: defaults))
            XCTAssertTrue(Shared.cleanupModelDiscoveryEnabled.projection(on: platform).value(in: defaults))
            XCTAssertEqual(Shared.liveTranscriptionModel.projection(on: platform).value(in: defaults),
                           "deepgram/nova-3-streaming")
        }
    }

    /// Each platform keeps its previous reading of a value it did not write itself.
    func testMalformedFlagsKeepEachPlatformsPreviousReading() {
        defaults.set("YES", forKey: "postProcessingEnabled")
        defaults.set("YES", forKey: "handsFreeDictationEnabled")
        defaults.set("NO", forKey: "keepAudioOnCancel")
        defaults.set("bogus", forKey: "visualDensity")
        // macOS cast with `as? Bool` and fell back to its default.
        XCTAssertTrue(Shared.postProcessingEnabled.macOS.value(in: defaults))
        XCTAssertFalse(Shared.handsFreeDictationEnabled.macOS.value(in: defaults))
        #if canImport(Darwin)
        // iOS read these through `UserDefaults.bool(forKey:)`, which coerces strings on Apple platforms.
        XCTAssertTrue(Shared.postProcessingEnabled.iOS.value(in: defaults))
        XCTAssertTrue(Shared.handsFreeDictationEnabled.iOS.value(in: defaults))
        #endif
        // Both read keepAudioOnCancel with `as? Bool`.
        XCTAssertTrue(Shared.keepAudioOnCancel.iOS.value(in: defaults))
        XCTAssertEqual(Shared.visualDensity.iOS.value(in: defaults), .normal)
    }
}
