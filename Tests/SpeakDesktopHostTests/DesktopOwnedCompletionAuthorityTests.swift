import Foundation
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost
import XCTest

@MainActor
final class DesktopOwnedCompletionAuthorityTests: XCTestCase {
    func testOwnedCancellationWithRecoveryText_IsExplicitAutomationFailure() async throws {
        let fixture = AutoCleanHostFixture()
        try await fixture.prepare(owned: true)
        addTeardownBlock { try await fixture.cleanup() }
        await fixture.toggle()
        fixture.effects.client.emit("retained recovery text")
        let active = await fixture.host.ownedDictation
        let id = try XCTUnwrap(active?.id)
        await fixture.host.cancelTranscription()
        let stopping = await fixture.host.ownedDictation?.stop
        await stopping?.value
        let record = try await fixture.record()
        XCTAssertEqual(record.originalText, "retained recovery text")
        XCTAssertTrue(record.failure?.contains("cancelled") == true)
        XCTAssertNil(record.processedText)
        XCTAssertTrue(fixture.effects.outputs.isEmpty)
        do {
            _ = try await fixture.host.completedDictationRecord(id)
            XCTFail("Retained partial text must not hide cancellation from automation.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("cancelled"))
        }
    }

    func testFailedOwnedPolishWithRawTranscript_IsExplicitAutomationFailure() async throws {
        let fixture = AutoCleanHostFixture()
        try await fixture.prepare(owned: true)
        addTeardownBlock { try await fixture.cleanup() }
        fixture.effects.failPolish()
        await fixture.toggle()
        await fixture.toggle()
        let record = try await fixture.record()
        XCTAssertEqual(record.originalText, "authoritative raw")
        XCTAssertNotNil(record.postProcessingFailure)
        XCTAssertNil(record.livePolishResult?.text)
        XCTAssertTrue(fixture.effects.outputs.isEmpty)
        do {
            _ = try await fixture.host.completedDictationRecord(record.id)
            XCTFail("Failed polish with retained raw text must not report owned automation success.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Injected Auto-Clean failure"))
        }
    }

    func testRetainedOwnedRetirementFailure_DoesNotReleaseCompletionAuthority() async throws {
        let fixture = OwnedDictationHostFixture()
        await fixture.worker.configure(retirementFailures: 1)
        try await fixture.prepare()
        addTeardownBlock { try await fixture.cleanup() }
        await fixture.toggle()
        let active = try await fixture.active()
        await fixture.toggle()
        let retained = await fixture.host.ownedDictation
        XCTAssertEqual(retained?.id, active.id)
        let finishes = await active.owner.finishCount
        XCTAssertEqual(finishes, 0)
        XCTAssertTrue(fixture.effects.transcriptions.isEmpty)
        do {
            _ = try await fixture.host.completedDictationRecord(active.id)
            XCTFail("A retained owner cannot issue a successful terminal recording.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("retirement is incomplete"))
        }
        try await fixture.host.retryOwnedDictation(requestID: active.id)
        let records = try await fixture.records()
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.id, active.id)
        XCTAssertNotNil(record.failure, "An acknowledged retry must not erase the historical first failure.")
        XCTAssertTrue(fixture.effects.transcriptions.isEmpty)
        let audio = try await fixture.audio(record)
        try assertDictationWAV(audio, samples: Array(Int16(1)...Int16(73)))
        do {
            _ = try await fixture.host.completedDictationRecord(active.id)
            XCTFail("Safe retry retirement does not retroactively authorize a failed transcript.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("retirement failed"))
        }
        let completedFinishes = await active.owner.finishCount
        XCTAssertEqual(completedFinishes, 1)
    }
}
