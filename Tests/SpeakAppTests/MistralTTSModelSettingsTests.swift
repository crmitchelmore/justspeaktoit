import Foundation
import SpeakCore
import XCTest

@testable import SpeakApp

final class MistralTTSModelSettingsTests: XCTestCase {
    @MainActor
    func testSavedPreviewModel_ReachesSpeechClientAndSurvivesMigrationReload() async throws {
        let suite = "MistralTTSModelSettings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.mistralTTSModel, .voxtralMiniTTS2603)
        settings.mistralTTSModel = .voxtralMiniTTS3
        XCTAssertEqual(defaults.string(forKey: "mistralTTSModel"), "voxtral-mini-tts-3-0")

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.mistralTTSModel, .voxtralMiniTTS3)
        defaults.set(MistralTTSModel.voxtralMiniTTS2603.rawValue, forKey: "mistralTTSModel")
        reloaded.reloadAfterMigration()
        XCTAssertEqual(reloaded.mistralTTSModel, .voxtralMiniTTS2603)
        reloaded.mistralTTSModel = .voxtralMiniTTS3
        reloaded.ttsAutoPlay = false
        reloaded.ttsSaveToDirectory = false
        let client = MistralSettingsCaptureClient()
        let storage = SecureAppStorage(
            permissionsManager: PermissionsManager(), appSettings: reloaded,
            keychainService: "com.justspeaktoit.tests.mistral-model.\(UUID().uuidString)"
        )
        let manager = TextToSpeechManager(
            appSettings: reloaded, secureStorage: storage, clients: [.mistral: client], defaults: defaults
        )
        do {
            _ = try await manager.synthesize(text: "[emotion=happy]Hello", voice: "mistral/synthetic-voice")
            XCTFail("The capture client should stop before audio generation")
        } catch {
            let capturedModel = await client.capturedModel
            XCTAssertEqual(capturedModel, .voxtralMiniTTS3)
        }
    }

    @MainActor
    func testUnknownSavedModel_FallsBackToPinnedLegacyWithoutChangingStoredVoice() throws {
        let suite = "MistralTTSFallback-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("future-unsupported-model", forKey: "mistralTTSModel")
        defaults.set("mistral/synthetic-voice", forKey: "defaultTTSVoice")
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.mistralTTSModel, .voxtralMiniTTS2603)
        XCTAssertEqual(settings.defaultTTSVoice, "mistral/synthetic-voice")
    }
}

private actor MistralSettingsCaptureClient: TextToSpeechClient {
    let provider: TTSProvider = .mistral
    private(set) var capturedModel: MistralTTSModel?

    func synthesize(text: String, voice: String, settings: TTSSettings) async throws -> TTSResult {
        capturedModel = settings.mistralModel
        throw TTSError.synthesisFailure("Captured without contacting a provider")
    }

    func listVoices() async throws -> [TTSVoice] { [] }

    func validateAPIKey(_ key: String) async -> APIKeyValidationResult {
        APIKeyValidationResult(outcome: .success(message: "Synthetic key"), debug: nil)
    }
}
