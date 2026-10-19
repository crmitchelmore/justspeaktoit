import Foundation
import XCTest
@testable import SpeakDesktop

final class DesktopRecordingLocationActivationTests: XCTestCase {
    func testActivateAudioLocations_installsOnceAndExposesOnlyRegisteredRoots() async throws {
        let fixture = try RecordingLocationFixture()
        defer { try? fixture.clean() }
        let store = try DesktopRecordingStore(directory: fixture.history)
        let hadLocations = await store.hasAudioLocations
        XCTAssertFalse(hadLocations)
        do {
            _ = try await store.authorizeLocallySelectedAudioRoot(fixture.first)
            XCTFail("A store without activated locations must not authorise a folder.")
        } catch {}

        let locations = try DesktopRecordingLocations(historyDirectory: fixture.history, persistence: fixture.memory)
        try await store.activateAudioLocations(locations)
        let hasLocations = await store.hasAudioLocations
        XCTAssertTrue(hasLocations)
        let id = try await store.authorizeLocallySelectedAudioRoot(fixture.first)
        let root = await store.audioLocationRoot(id)
        XCTAssertEqual(root?.standardizedFileURL.path, fixture.first.standardizedFileURL.path)
        let unknown = await store.audioLocationRoot(UUID())
        XCTAssertNil(unknown)

        let replacement = try DesktopRecordingLocations(
            historyDirectory: fixture.history, persistence: RecordingLocationMemoryPersistence()
        )
        do {
            try await store.activateAudioLocations(replacement)
            XCTFail("Activated locations must never be replaced.")
        } catch DesktopRecordingLocationError.duplicateIdentity {}
        let kept = await store.audioLocationRoot(id)
        XCTAssertNotNil(kept)
    }

    func testActivateAudioLocations_rejectsAnotherHistory() async throws {
        let fixture = try RecordingLocationFixture()
        defer { try? fixture.clean() }
        let store = try DesktopRecordingStore(directory: fixture.history)
        let foreign = try DesktopRecordingLocations(historyDirectory: fixture.second, persistence: fixture.memory)
        do {
            try await store.activateAudioLocations(foreign)
            XCTFail("Locations bound to another History must be refused.")
        } catch DesktopRecordingLocationError.foreignRegistration {}
        let hasLocations = await store.hasAudioLocations
        XCTAssertFalse(hasLocations)
    }
}
