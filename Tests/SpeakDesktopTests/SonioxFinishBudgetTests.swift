import Foundation
import XCTest
@testable import SpeakCore

final class SonioxFinishBudgetTests: XCTestCase {
    func testOriginalInitializerPreservesEightSecondFinishDeadline() {
        let fixture = SonioxLiveFixture()
        fixture.start()
        fixture.becomeReady()
        fixture.client.stop()
        XCTAssertEqual(fixture.clock.pending(8), 1)
        XCTAssertEqual(fixture.clock.pending(3.5), 0)
        fixture.client.cancel()
    }

    func testExplicitBudgetBoundsBothPendingSendAndCompletion() {
        let socket = AssemblyAITestSocket()
        let clock = AssemblyAITestClock()
        let events = AssemblyAITestEvents()
        let client = SonioxLiveClient(
            apiKey: "synthetic", makeConnection: { _ in socket },
            schedule: { clock.schedule($0, action: $1) }, finishTimeout: 3.5
        )
        client.start(onTranscript: { _, _ in }, onError: { events.fail($0) })
        socket.open()
        socket.completeSend()
        client.sendAudio(Data(repeating: 1, count: 3_200))
        client.stop()
        XCTAssertEqual(clock.pending(3.5), 1)
        XCTAssertEqual(clock.pending(8), 0)
        clock.fire(3.5)
        XCTAssertEqual(events.errors.count, 1)
        XCTAssertEqual(socket.binary.count, 1, "A stuck audio send must not be overtaken by end-of-stream")
        XCTAssertEqual(socket.cancels, 1)
    }
}
