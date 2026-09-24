import Foundation
import XCTest
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost

/// The Azure Speech resource endpoint both desktop hosts save: only an origin
/// the shared clients accept is kept, and live Azure refuses to start without it.
final class DesktopHostAzureResourceTests: XCTestCase {
    private var directory: URL!
    private var controller: DesktopHostController<FakePlatform>!

    override func setUp() async throws {
        FakeLog.shared.reset()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("azure-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        controller = try DesktopHostController<FakePlatform>(directory: directory, effects: SyntheticEffects())
        await controller.markReadyForSelfTest()
    }

    override func tearDown() async throws {
        await controller.close()
        try? FileManager.default.removeItem(at: directory)
    }

    func testEntriesAreTrimmedAndOnlyResourceOriginsAreAccepted() throws {
        XCTAssertEqual(
            try DesktopHostAzureResource.normalized("  https://example.cognitiveservices.azure.com  "),
            "https://example.cognitiveservices.azure.com"
        )
        XCTAssertEqual(try DesktopHostAzureResource.normalized("   "), "")
        for rejected in [
            "http://example.cognitiveservices.azure.com",
            "https://example.com",
            "https://example.cognitiveservices.azure.com/speech"
        ] {
            XCTAssertThrowsError(try DesktopHostAzureResource.normalized(rejected), rejected) { error in
                XCTAssertEqual(error.localizedDescription, DesktopHostAzureResource.invalidEndpoint)
            }
        }
    }

    func testLiveAzureNeedsTheEndpointAndRecordedAudioDoesNot() async throws {
        let live = AzureTranscriptionModels.speechLive
        XCTAssertEqual(DesktopLiveTranscription.route(forID: live)?.provider, .azure)
        do {
            try await controller.requireAzureResource(forLive: live)
            XCTFail("Live Azure must refuse to start without a saved resource endpoint")
        } catch {
            XCTAssertEqual(error.localizedDescription, DesktopHostAzureResource.missingForLive)
        }
        try await controller.requireAzureResource(forLive: AzureTranscriptionModels.fast)

        await controller.saveAzureResourceEndpoint("https://example.cognitiveservices.azure.com")
        try await controller.requireAzureResource(forLive: live)
        XCTAssertEqual(FakeLog.shared.allStatuses.last, "Azure Speech resource endpoint saved.")
    }

    func testTheSavedEndpointPersistsAndAnEmptyEntryClearsIt() async throws {
        await controller.saveAzureResourceEndpoint("https://example.cognitiveservices.azure.com")
        await controller.close()
        controller = try DesktopHostController<FakePlatform>(directory: directory, effects: SyntheticEffects())
        let restored = await controller.azureResourceEndpoint()
        XCTAssertEqual(restored, "https://example.cognitiveservices.azure.com")

        await controller.markReadyForSelfTest()
        await controller.saveAzureResourceEndpoint("")
        let cleared = await controller.azureResourceEndpoint()
        XCTAssertEqual(cleared, "")
        XCTAssertEqual(
            FakeLog.shared.allStatuses.last,
            "Azure Speech resource endpoint cleared. Recorded audio uses the region in your Azure key."
        )
    }

    func testSelectingALiveAzureModelSaysWhereTheEndpointGoes() {
        XCTAssertTrue(
            DesktopHostAzureResource.selectionHint(for: AzureTranscriptionModels.speechLive)
                .contains("Azure Speech resource")
        )
        XCTAssertFalse(
            DesktopHostAzureResource.selectionHint(for: AzureTranscriptionModels.fast)
                .contains("Azure Speech resource")
        )
    }
}
