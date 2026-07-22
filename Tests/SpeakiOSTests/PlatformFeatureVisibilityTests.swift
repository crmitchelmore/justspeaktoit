#if os(iOS)
import SpeakCore
import XCTest

@testable import SpeakiOSLib

@MainActor
final class PlatformFeatureVisibilityTests: XCTestCase {
    func testRemoteLivePicker_omitsProvidersWithoutAnIOSImplementation() {
        let visibleModels = AppSettings.supportedLiveModels
        let visibleIDs = Set(visibleModels.map(\.id))

        XCTAssertFalse(visibleModels.isEmpty)
        XCTAssertTrue(visibleModels.allSatisfy { option in
            LiveTranscriptionRouting.route(for: option.id)?.isSupportedOnIOS == true
        })
        XCTAssertTrue(
            ModelCatalog.remoteLiveTranscription
                .filter { LiveTranscriptionRouting.route(for: $0.id)?.isSupportedOnIOS == false }
                .allSatisfy { !visibleIDs.contains($0.id) }
        )
        XCTAssertFalse(visibleIDs.contains { $0.hasPrefix("speechmatics/") })
    }

    func testRemoteBatchPicker_omitsProvidersWithoutAnIOSUploadPath() {
        let visibleProviders = Set(AppSettings.supportedBatchModels.map { option in
            String(option.id.prefix { $0 != "/" })
        })

        XCTAssertEqual(visibleProviders, ["google", "openai"])
    }
}
#endif
