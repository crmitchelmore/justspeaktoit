import Foundation
import XCTest

@testable import SpeakCore

/// The capability registry is what `AppSettings.enforceSpeedModeConstraints()`
/// consults, and its fallback is `instant`-only. A cloud model missing from the
/// registry therefore does not just lose Live Polish: selecting it permanently
/// rewrites the user's stored speed mode.
final class LiveModelCapabilitiesTests: XCTestCase {

    func testEveryCredentialedLiveModel_hasAnExplicitCapabilityEntry() {
        let missing = LiveTranscriptionRouting.allRoutes
            .filter { $0.apiKeyIdentifier != nil }
            .map(\.modelID)
            .filter { ModelCatalog.liveCapabilityRegistry[$0] == nil }

        XCTAssertEqual(
            missing,
            [],
            "Add these to ModelCatalog.liveCapabilityRegistry; the default is instant-only "
                + "and silently rewrites the user's speed mode."
        )
    }

    func testMetaMuseVoice_supportsLivePolishLikeEveryOtherSegmentStreamer() {
        let capabilities = ModelCatalog.liveCapabilities(for: MetaMuseVoiceTranscribe.liveCatalogID)

        XCTAssertTrue(capabilities.supportedSpeedModes.contains(.instant))
        XCTAssertTrue(capabilities.supportedSpeedModes.contains(.livePolish))
    }

    func testUnknownModel_stillFallsBackToInstantOnly() {
        let capabilities = ModelCatalog.liveCapabilities(for: "nobody/nothing-streaming")

        XCTAssertEqual(capabilities.supportedSpeedModes, [.instant])
        XCTAssertEqual(capabilities.postStopFinalizeBudget, 0)
    }
}
