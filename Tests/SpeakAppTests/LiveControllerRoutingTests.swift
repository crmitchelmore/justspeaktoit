import Foundation
import SpeakCore
import XCTest

@testable import SpeakApp

@MainActor
final class LiveControllerRoutingTests: XCTestCase {
    private func makeSwitcher() throws -> SwitchingLiveTranscriber {
        let suite = "live-controller-routing.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let permissions = PermissionsManager()
        return SwitchingLiveTranscriber(
            appSettings: settings, permissionsManager: permissions,
            audioDeviceManager: AudioInputDeviceManager(appSettings: settings),
            secureStorage: SecureAppStorage(
                permissionsManager: permissions, appSettings: settings,
                keychainService: "com.justspeaktoit.tests.live-routing.\(UUID().uuidString)"
            )
        )
    }

    func testEveryCataloguedCloudLiveModel_routesToItsProvidersController() throws {
        let switcher = try makeSwitcher()
        for route in LiveTranscriptionRouting.allRoutes where route.provider != .apple {
            let controller = switcher.controller(for: route.modelID)
            switch route.provider {
            case .openai: XCTAssertTrue(controller is OpenAIRealtimeLiveController, route.modelID)
            case .deepgram: XCTAssertTrue(controller is DeepgramLiveController, route.modelID)
            case .modulate: XCTAssertTrue(controller is ModulateLiveController, route.modelID)
            case .elevenlabs: XCTAssertTrue(controller is ElevenLabsLiveController, route.modelID)
            case .soniox: XCTAssertTrue(controller is SonioxLiveController, route.modelID)
            default: XCTAssertTrue(controller is SharedClientLiveController, route.modelID)
            }
        }
    }

    func testUnknownAndOnDeviceIdentifiers_neverReachACloudController() throws {
        let switcher = try makeSwitcher()
        for model in [
            "google/gemini-2.5-flash", "Deepgram/nova-3-streaming", " deepgram/nova-3-streaming",
            "unknown/model", "apple/local/Dictation", "local/batch/whisper"
        ] {
            XCTAssertNil(SwitchingLiveTranscriber.cloudProvider(for: model), model)
            let controller = switcher.controller(for: model)
            XCTAssertFalse(controller is SharedClientLiveController, model)
            XCTAssertFalse(controller is OpenAIRealtimeLiveController, model)
        }
    }
}
