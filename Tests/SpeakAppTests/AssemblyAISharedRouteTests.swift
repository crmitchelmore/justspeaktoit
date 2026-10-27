import Foundation
import SpeakCore
import XCTest

@testable import SpeakApp

@MainActor
final class AssemblyAISharedRouteTests: XCTestCase {
    func testAssemblyAIUsesSharedControllerWithoutChangingOtherCaptureOwners() throws {
        let suite = "assemblyai-shared-route.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let permissions = PermissionsManager()
        let switcher = SwitchingLiveTranscriber(
            appSettings: settings, permissionsManager: permissions,
            audioDeviceManager: AudioInputDeviceManager(appSettings: settings),
            secureStorage: SecureAppStorage(
                permissionsManager: permissions, appSettings: settings,
                keychainService: "com.justspeaktoit.tests.assemblyai-route.\(UUID().uuidString)"
            )
        )
        let shared = switcher.controller(for: AssemblyAIModels.universal36ProStreamingID)
        XCTAssertTrue(shared is SharedClientLiveController)
        XCTAssertTrue(shared === switcher.controller(for: "assemblyai/universal-streaming"))
        XCTAssertTrue(switcher.usesLiveInputEngine(for: AssemblyAIModels.universal36ProStreamingID))
        XCTAssertTrue(switcher.controller(for: "openai/gpt-live-transcribe") is OpenAIRealtimeLiveController)
        XCTAssertTrue(switcher.controller(for: AppleLocalModels.speechTranscriberModelID)
            is AppleSpeechAnalyzerLiveController)
        XCTAssertTrue(switcher.controller(for: "local/streaming/whisperkit/tiny") is WhisperKitLiveController)
        XCTAssertFalse(switcher.usesLiveInputEngine(for: "local/streaming/whisperkit/tiny"))
    }
}
