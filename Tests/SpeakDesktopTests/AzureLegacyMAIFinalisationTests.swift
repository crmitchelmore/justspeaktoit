import Foundation
import XCTest
@testable import SpeakCore

final class AzureLegacyMAIFinalisationTests: XCTestCase {
    func testLegacyTimeoutIdentifiesRouteAndBudgetAfterPublishingRetainedText() async throws {
        let fixture = AzureVoiceLiveFixture(model: "mai-transcribe")
        fixture.start()
        fixture.becomeReady()
        fixture.client.sendAudio(AzureVoiceLiveFixture.frame(0))
        let finish = await fixture.finishThroughBarrier(committing: "confirmed")
        fixture.socket.committed("pending")
        fixture.socket.completed("Confirmed.", item: "confirmed")
        fixture.socket.delta("Recovery draft", item: "pending")
        fixture.socket.acknowledge(sessionType: nil)
        XCTAssertTrue(fixture.log.entries.isEmpty, "A pending turn must keep finalisation open")
        XCTAssertEqual(fixture.client.finishBudget, 5, "The legacy finish budget must not grow")
        fixture.clock.fire(5)
        let result = await self.result(of: finish, fixture: fixture)
        XCTAssertEqual(result, "Confirmed.")
        let error = try XCTUnwrap(fixture.events.errors.first as? AzureLegacyMAIFinalisationTimeout)
        XCTAssertEqual(fixture.events.errors.count, 1)
        XCTAssertEqual(error.budget, 5)
        XCTAssertEqual(error.errorDescription,
                       "Azure MAI Transcribe (Turn-based) did not return a final transcript within 5 seconds. "
                       + "Check this model's availability on your Azure resource, or explicitly choose another "
                       + "configured transcription model. Any text already received remains available for recovery.")
        let entries = fixture.log.entries
        guard entries.count == 4 else { return XCTFail("Expected retained finals, draft, error and finish in order") }
        XCTAssertEqual(entries.first, .transcript("Confirmed.", final: true))
        XCTAssertEqual(entries[1], .transcript("Confirmed. Recovery draft", final: false))
        guard case .error = entries[2] else { return XCTFail("Error must precede finish result") }
        XCTAssertEqual(entries.last, .finished("Confirmed."))
        XCTAssertEqual(fixture.socket.cancels, 1)
        let snapshot = fixture.client.transcriptSnapshot(captureDuration: 1)
        XCTAssertEqual(snapshot.confirmedText, "Confirmed.")
        XCTAssertEqual(snapshot.displayText, "Confirmed. Recovery draft")
        XCTAssertTrue(snapshot.isTerminal)
        XCTAssertEqual(fixture.factory.sockets.count, 1, "A timeout must not silently switch resources")
    }

    func testOtherAzureRoutesKeepExistingTimeoutErrorsAndBudgets() async throws {
        for model in ["azure-speech", "mai-transcribe-2-streaming"] {
            let fixture = AzureVoiceLiveFixture(model: model)
            fixture.start()
            fixture.becomeReady()
            fixture.client.sendAudio(AzureVoiceLiveFixture.frame(0))
            let finish = fixture.finish()
            await fixture.waitForFinishers()
            fixture.completeSends(until: "input_audio_buffer.commit")
            fixture.socket.committed("pending")
            fixture.socket.completeSend()
            if model == "azure-speech" {
                fixture.socket.completeSend()
                fixture.socket.acknowledge(sessionType: nil)
            }
            fixture.clock.fire(fixture.client.finishBudget)
            let result = await self.result(of: finish, fixture: fixture)
            XCTAssertNil(result)
            XCTAssertEqual(fixture.events.errors.count, 1)
            guard case .timedOut? = fixture.events.errors.first as? AzureSpeechError else {
                return XCTFail("Other Azure routes must retain their timeout error: \(model)")
            }
            XCTAssertNil(fixture.events.errors.first as? AzureLegacyMAIFinalisationTimeout)
            XCTAssertEqual(fixture.factory.sockets.count, 1)
        }
    }

    func testLegacyHandshakeAndStalledTransportKeepTheirOwnErrors() async throws {
        for ready in [false, true] {
            let fixture = AzureVoiceLiveFixture(model: "mai-transcribe")
            fixture.start()
            if ready {
                fixture.becomeReady()
            } else {
                // Configuration reached the wire, but Azure never acknowledged it.
                fixture.socket.open()
                fixture.socket.completeSend()
            }
            fixture.client.sendAudio(AzureVoiceLiveFixture.frame(0))
            let finish = fixture.finish()
            await fixture.waitForFinishers()
            fixture.clock.fire(fixture.client.finishBudget)
            let result = await self.result(of: finish, fixture: fixture)
            XCTAssertNil(result)
            XCTAssertEqual(fixture.events.errors.count, 1)
            XCTAssertNil(fixture.events.errors.first as? AzureLegacyMAIFinalisationTimeout,
                         "A resource/finalisation message must not mask a handshake or transport failure")
            if ready {
                let transportError = fixture.events.errors.first as? StreamingClientError
                guard case .transportStalled(let provider)? = transportError else {
                    return XCTFail("A blocked transport must keep its stalled error")
                }
                XCTAssertEqual(provider, "Azure Speech")
            } else {
                XCTAssertEqual(fixture.events.errors.first as? AzureVoiceLiveError, .sessionNotReady)
            }
        }
    }

    private func result(of finish: Task<String?, Never>, fixture: AzureVoiceLiveFixture) async -> String? {
        let completed = XCTestExpectation(description: "Synthetic finalisation returned")
        let observed = Task {
            let result = await finish.value
            completed.fulfill()
            return result
        }
        defer { fixture.client.cancel(); finish.cancel(); observed.cancel() }
        guard await XCTWaiter.fulfillment(of: [completed], timeout: 2) == .completed else {
            XCTFail("Synthetic finalisation must settle promptly after the clock fires")
            return nil
        }
        return await observed.value
    }

}
