import Foundation
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost
import XCTest

@MainActor
final class DesktopHostLivePolishPreviewTests: XCTestCase {
    func testActualPresentation_UsesPolishedPreviewThenImmediatelyClearsRetractionWithoutInsertion() async throws {
        let fixture = AutoCleanHostFixture()
        try await fixture.prepare(enabled: false)
        addTeardownBlock { try await fixture.cleanup() }
        await fixture.toggle()
        let active = await fixture.host.recording
        let id = try XCTUnwrap(active?.record.id)
        let complete = expectation(description: "polished")
        let polish = LivePolishSession(
            recordingID: id, preferences: .init(mode: .livePolish), modelIdentifier: "synthetic",
            onChange: { result in if result.succeeded { complete.fulfill() } },
            complete: { _ in "Clean preview." }
        )
        let client = AutoCleanStreamingClient()
        let session = DesktopLiveSession(client: client, id: id, keywordLimitation: nil, livePolish: polish)
        session.start()
        client.emit("raw preview", final: true)
        await fulfillment(of: [complete], timeout: 2)
        await fixture.host.publishLivePreview(session)
        XCTAssertEqual(FakeLog.shared.transcripts.last, "Clean preview.")
        XCTAssertEqual(FakeLog.shared.huds.last?.liveText, "Clean preview.")
        XCTAssertEqual(session.snapshot().text, "raw preview")
        client.emit("")
        await fixture.host.publishLivePreview(session)
        XCTAssertEqual(FakeLog.shared.transcripts.last, "")
        XCTAssertNil(FakeLog.shared.huds.last?.liveText)
        XCTAssertTrue(fixture.effects.outputs.isEmpty)
        session.cancel()
        let before = FakeLog.shared.transcripts
        client.emit("stale")
        await fixture.host.publishLivePreview(session)
        XCTAssertEqual(FakeLog.shared.transcripts, before)
    }

    func testSilentAuthoritativeTranscript_StaysEmptyWithoutCleanupRequestOrClaimedSuccess() async throws {
        let fixture = AutoCleanHostFixture()
        try await fixture.prepare()
        addTeardownBlock { try await fixture.cleanup() }
        fixture.effects.client.finalText = " \n "
        await fixture.toggle()
        await fixture.toggle()
        let record = try await fixture.record()
        XCTAssertEqual(record.originalText, "")
        XCTAssertFalse(record.livePolishResult?.succeeded ?? false)
        XCTAssertNil(record.livePolishResult?.text)
        XCTAssertTrue(fixture.effects.cleanups.isEmpty)
        XCTAssertTrue(fixture.effects.outputs.isEmpty)
    }
}
