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

    private func makeDefaults() -> UserDefaults {
        let suiteName = "OnboardingStateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
