import Foundation
import XCTest
@testable import SpeakCore

final class OpenAIRealtimePaddingBudgetTests: XCTestCase {
    func testShortTailReservationRefusesAudioThatCouldNotBeCommittedWithinTheBudget() {
        let fixture = OpenAIRealtimeLiveFixture()
        fixture.start()
        let prefix = Data(repeating: 7, count: 239_996)
        fixture.client.sendAudio(prefix)
        fixture.client.commitInputBuffer()
        fixture.client.sendAudio(Data([1, 0]))
        fixture.client.commitInputBuffer()
        XCTAssertEqual(fixture.events.errors.first as? OpenAIRealtimeStreamingError, .audioOverflow)
        XCTAssertEqual(fixture.client.queuedAudioByteCount, prefix.count)
        fixture.becomeReady()
        fixture.socket.completeSend()
        fixture.socket.completeSend()
        XCTAssertEqual(fixture.socket.audio, [prefix], "The admitted prefix survives; no unreserved padding is sent")
        fixture.client.cancel()
    }

    func testManyShortCommitsShareTheSameFiveSecondBudgetIncludingPadding() {
        let fixture = OpenAIRealtimeLiveFixture()
        fixture.start()
        for _ in 0..<50 {
            fixture.client.sendAudio(Data([1, 0]))
            fixture.client.commitInputBuffer()
        }
        XCTAssertEqual(fixture.client.queuedAudioByteCount, 240_000)
        XCTAssertTrue(fixture.events.errors.isEmpty)
        fixture.client.sendAudio(Data([1, 0]))
        fixture.client.commitInputBuffer()
        XCTAssertEqual(fixture.events.errors.count, 1)
        XCTAssertEqual(fixture.client.queuedAudioByteCount, 240_000)
        fixture.becomeReady()
        for _ in 0..<150 { fixture.socket.completeSend() }
        XCTAssertEqual(fixture.socket.audio.count, 100)
        XCTAssertEqual(fixture.socket.audio.reduce(0) { $0 + $1.count }, 240_000)
        for pair in stride(from: 0, to: 100, by: 2) {
            XCTAssertEqual(fixture.socket.audio[pair], Data([1, 0]))
            XCTAssertEqual(fixture.socket.audio[pair + 1], Data(count: 4_798))
        }
        fixture.client.cancel()
    }

    func testTinyFramesReserveOneFinalPaddingSlotWithinTheFrameBound() {
        let fixture = OpenAIRealtimeLiveFixture()
        fixture.start()
        let count = OpenAIRealtimeLiveClient.maximumQueuedFrames - 1
        for _ in 0..<count { fixture.client.sendAudio(Data([1, 0])) }
        XCTAssertTrue(fixture.events.errors.isEmpty)
        fixture.client.sendAudio(Data([1, 0]))
        XCTAssertEqual(fixture.events.errors.count, 1)
        fixture.client.commitInputBuffer()
        fixture.becomeReady()
        for _ in 0..<count + 2 { fixture.socket.completeSend() }
        XCTAssertEqual(fixture.socket.audio.count, OpenAIRealtimeLiveClient.maximumQueuedFrames)
        XCTAssertEqual(fixture.socket.audio.last, Data(count: 4_800 - count * 2))
        XCTAssertEqual(fixture.socket.audio.reduce(0) { $0 + $1.count }, 4_800)
        fixture.client.cancel()
    }

    func testExtremeInvalidRatesFailBeforeCreatingATransportWithoutAllocationOverflow() {
        for value in [Int.max, Int.min, 0, -1] {
            let fixture = OpenAIRealtimeLiveFixture(sampleRate: value)
            fixture.start()
            XCTAssertTrue(fixture.factory.sockets.isEmpty)
            XCTAssertEqual(fixture.events.errors.first as? OpenAIRealtimeStreamingError, .invalidSampleRate(value))
        }
    }
}
