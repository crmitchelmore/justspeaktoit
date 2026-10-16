import Foundation
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost
import XCTest

@MainActor
final class DesktopHostLivePolishCancellationTests: XCTestCase {
    func testOwnedCancellationDuringFinalPolish_PreservesRawWithoutWaitingForWorker() async throws {
        let fixture = AutoCleanHostFixture()
        try await fixture.prepare(owned: true)
        addTeardownBlock { try await fixture.cleanup() }
        let requested = expectation(description: "owned final cleanup")
        fixture.effects.holdPolish { requested.fulfill() }
        await fixture.toggle()
        let stopping = Task { await fixture.toggle() }
        await fulfillment(of: [requested], timeout: 2)
        await fixture.host.cancelTranscription()
        await stopping.value
        let record = try await fixture.record()
        XCTAssertEqual(record.originalText, "authoritative raw")
        XCTAssertNil(record.processedText)
        XCTAssertTrue(record.failure?.contains("Cancelled") == true)
        XCTAssertTrue(fixture.effects.outputs.isEmpty)
        let owned = await fixture.host.ownedDictation
        XCTAssertNil(owned, "Cancellation must finish disposition without joining a non-cooperative LLM")
        fixture.effects.releasePolish()
        XCTAssertNil(record.livePolishResult?.text)
    }

    func testProviderFailure_RetiresPendingCleanupAndKeepsRawRecoveryText() async throws {
        let fixture = AutoCleanHostFixture()
        try await fixture.prepare()
        addTeardownBlock { try await fixture.cleanup() }
        await fixture.toggle()
        let active = await fixture.host.recording
        let id = try XCTUnwrap(active?.record.id)
        fixture.effects.client.emit("recovery text")
        fixture.effects.client.fail()
        await fixture.host.captureFailed("Injected live provider failure.", recordingID: id)
        let record = try await fixture.record()
        XCTAssertEqual(record.originalText, "recovery text")
        XCTAssertEqual(record.failure, "Injected live provider failure.")
        XCTAssertNil(record.processedText)
        XCTAssertTrue(fixture.effects.cleanups.isEmpty)
        XCTAssertTrue(fixture.effects.outputs.isEmpty)
        XCTAssertEqual(active?.live?.livePolish?.snapshot().failure, LivePolishError.cancelled.localizedDescription)
    }
}
