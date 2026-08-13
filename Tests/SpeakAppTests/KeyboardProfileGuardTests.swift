import Foundation
import XCTest

/// Source-level distribution guards complement the behavioural SpeakCore tests
/// because the keyboard extension itself has no unit-test target.
final class KeyboardProfileGuardTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent(path), encoding: .utf8)
    }

    func testExtensionRoutesAppProfilesWithoutResolvingCredentials() throws {
        let model = try source("JustSpeakKeyboard/KeyboardViewModel.swift")
        let handoff = try source("JustSpeakKeyboard/KeyboardHandoffController.swift")

        XCTAssertTrue(model.contains("profileSelection.route == .appHandoff"))
        XCTAssertTrue(handoff.contains("profile: profile"))
        for keyboardSource in [model, handoff] {
            XCTAssertFalse(keyboardSource.contains("URLSession"))
            XCTAssertFalse(keyboardSource.lowercased().contains("apikey"))
        }
    }

    func testProfileMenuShowsRouteAndIsDisabledWhileBusy() throws {
        let rootView = try source("JustSpeakKeyboard/KeyboardRootView.swift")

        XCTAssertTrue(rootView.contains("Menu {"))
        XCTAssertTrue(rootView.contains("profile.route.displayName"))
        XCTAssertTrue(rootView.contains("model.selectProfile(profile.id)"))
        XCTAssertTrue(rootView.contains(".disabled(model.isBusy)"))
    }

    func testEveryOwningAppSettingPublishesAtItsMutationBoundary() throws {
        let settings = try source("Sources/SpeakiOS/Views/SettingsView.swift")
        let coordinator = try source("Sources/SpeakiOS/Services/KeyboardInstantDictationCoordinator.swift")

        for property in [
            "selectedModel", "transcriptionMode", "batchTranscriptionModel",
            "preferredLocaleIdentifier", "postProcessingEnabled", "postProcessingModel"
        ] {
            guard let propertyRange = settings.range(of: "@Published public var \(property)") else {
                return XCTFail("Missing \(property)")
            }
            let suffix = settings[propertyRange.lowerBound...].prefix(700)
            XCTAssertTrue(suffix.contains("publishKeyboardProfileSelection()"), "\(property) is not mirrored")
        }
        guard let languageRange = settings.range(of: "@Published public var preferredLocaleIdentifier") else {
            return XCTFail("Missing preferredLocaleIdentifier")
        }
        XCTAssertTrue(
            settings[languageRange.lowerBound...].prefix(700).contains("mirrorAppPreference"),
            "preferredLocaleIdentifier does not refresh the keyboard language ring"
        )
        XCTAssertTrue(coordinator.contains("AppSettings.shared.publishKeyboardProfileSelection()"))
    }
}
