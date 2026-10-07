import Foundation
import SpeakCore
import XCTest
@testable import SpeakDesktop

final class DesktopHistoryRetryTests: XCTestCase {
    /// The regression: on-device models have no remote provider, so the old
    /// provider-only test refused them as live models.
    func testOnDeviceModels_haveNoRemoteProviderYetRetryOnDevice() {
        let windows = DesktopLocalTranscription.models(host: .windows).map(\.catalogueID)
        XCTAssertFalse(windows.isEmpty, "Windows must offer at least one on-device model")
        for identifier in windows + ModelCatalog.localTranscription.map(\.id) {
            XCTAssertNil(DesktopTranscription.provider(for: identifier), identifier)
            XCTAssertEqual(DesktopHistoryRetry.route(for: identifier), .onDevice, identifier)
        }
        XCTAssertEqual(DesktopHistoryRetry.route(for: " Local/WhisperKit/Tiny \n"), .onDevice)
        XCTAssertEqual(DesktopHistoryRetry.route(for: "local/whisperkit/retired-size"), .onDevice)
    }

    func testRemoteBatchModels_retryRemotely() {
        XCTAssertFalse(DesktopTranscription.batchModels.isEmpty)
        for option in DesktopTranscription.batchModels {
            XCTAssertEqual(DesktopHistoryRetry.route(for: option.id), .remote, option.id)
        }
    }

    /// Live models without a batch route keep their import guidance, including
    /// a retired identifier the catalogue still migrates.
    func testLiveOnlyModels_areNotRetried() {
        let liveOnly = ModelCatalog.liveTranscription.filter { DesktopTranscription.provider(for: $0.id) == nil }
        XCTAssertFalse(liveOnly.isEmpty)
        for option in liveOnly {
            XCTAssertEqual(DesktopHistoryRetry.route(for: option.id), .liveOnly, option.id)
        }
        for identifier in DesktopLiveTranscription.liveModels.map(\.id)
        where DesktopTranscription.provider(for: identifier) == nil {
            XCTAssertEqual(DesktopHistoryRetry.route(for: identifier), .liveOnly, identifier)
        }
        for retired in AssemblyAIModels.legacyUniversal3StreamingIDs
        where DesktopTranscription.provider(for: retired) == nil {
            XCTAssertEqual(DesktopHistoryRetry.route(for: retired), .liveOnly, retired)
        }
    }

    func testUnknownModels_areUnavailableRatherThanLive() {
        for identifier in ["", "   ", "acme/retired-transcriber"] {
            XCTAssertEqual(DesktopHistoryRetry.route(for: identifier), .unavailable, identifier)
        }
    }
}
