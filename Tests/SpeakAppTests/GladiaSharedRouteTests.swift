import Foundation
import SpeakCore
import XCTest

@testable import SpeakApp

@MainActor
final class GladiaSharedRouteTests: XCTestCase {
    func testCanonicalGladiaLiveModelsUseCachedSharedCaptureController() throws {
        let suite = "gladia-shared-route.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let permissions = PermissionsManager()
        let switcher = SwitchingLiveTranscriber(
            appSettings: settings, permissionsManager: permissions,
            audioDeviceManager: AudioInputDeviceManager(appSettings: settings),
            secureStorage: SecureAppStorage(
                permissionsManager: permissions, appSettings: settings,
                keychainService: "com.justspeaktoit.tests.gladia-route.\(UUID().uuidString)"
            )
        )
        let shared = switcher.controller(for: AssemblyAIModels.universal36ProStreamingID)
        XCTAssertTrue(shared is SharedClientLiveController)
        let models = ModelCatalog.liveTranscriptionOptions(forProvider: "gladia")
        XCTAssertFalse(models.isEmpty)
        for model in models {
            XCTAssertTrue(switcher.controller(for: model.id) === shared, model.id)
            XCTAssertTrue(switcher.usesLiveInputEngine(for: model.id), model.id)
        }
        XCTAssertTrue(switcher.controller(for: "openai/gpt-live-transcribe") is OpenAIRealtimeLiveController)
    }
}
