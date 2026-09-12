import Combine
import XCTest

@testable import SpeakApp

final class OnboardingStateTests: XCTestCase {
    @MainActor
    func testKeylessCompletion_disablesUnavailablePostProcessing() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.postProcessingEnabled = true
        settings.postProcessingModel = "openai/gpt-5-mini"

        OnboardingState.disableUnavailablePostProcessing(in: settings)

        XCTAssertFalse(settings.postProcessingEnabled)
        XCTAssertFalse(defaults.bool(forKey: "postProcessingEnabled"))
    }

    @MainActor
    func testKeylessCompletion_preservesAvailableLocalPostProcessing() {
        let settings = AppSettings(defaults: makeDefaults())
        settings.postProcessingEnabled = true
        settings.postProcessingModel = "local/post-processing/rules"

        OnboardingState.disableUnavailablePostProcessing(in: settings)

        XCTAssertTrue(settings.postProcessingEnabled)
    }

    @MainActor
    func testPermissionChanges_updateOnboardingWithoutConfirmationOrAnotherPoll() {
        var accessibilityStatus = PermissionStatus.denied
        let permissions = PermissionsManager(statusProvider: { permission in
            permission == .accessibility ? accessibilityStatus : .granted
        })
        let environment = WireUp.bootstrap(options: makeWireUpTestOptions(permissionsOverride: permissions))
        let state = OnboardingState(
            permissionsManager: permissions,
            secureStorage: environment.secureStorage,
            settings: environment.settings,
            hotKeyManager: environment.hotKeys,
            audioFileManager: environment.audio,
            transcriptionManager: environment.transcription
        )
        XCTAssertFalse(state.permissionsGranted.contains(.accessibility))
        var snapshots: [Set<PermissionType>] = []
        let observer = state.$permissionsGranted.dropFirst().sink { snapshots.append($0) }
        defer { observer.cancel() }

        accessibilityStatus = .granted
        permissions.refresh(.accessibility) // The Settings guide performs this refresh.
        XCTAssertTrue(state.permissionsGranted.contains(.accessibility))
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertTrue(snapshots.allSatisfy { $0.contains(.microphone) }, "Never clear unrelated grants")

        permissions.refresh(.accessibility)
        XCTAssertEqual(snapshots.count, 1, "Repeated unchanged polls should not republish onboarding state")
        accessibilityStatus = .denied
        permissions.refresh(.accessibility)
        XCTAssertFalse(state.permissionsGranted.contains(.accessibility), "Revocation must also update immediately")
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "OnboardingStateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
