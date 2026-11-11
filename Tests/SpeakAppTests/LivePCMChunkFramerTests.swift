import Foundation
import XCTest

@testable import SpeakApp

final class LivePCMChunkFramerTests: XCTestCase {
    func testChunkSizes_are50And100MillisecondsOfPCM16At24kHz() {
        let framer = LivePCMChunkFramer(sampleRate: 24_000)
        XCTAssertEqual(framer.minimumChunkBytes, 2_400)
        XCTAssertEqual(framer.preferredChunkBytes, 4_800)
    }

    func testTakeFullChunks_emitsOnlyCompleteChunksInOrderAndKeepsTheRest() {
        var framer = LivePCMChunkFramer(sampleRate: 24_000)
        let audio = Data((0..<10_000).map { UInt8(truncatingIfNeeded: $0) })
        framer.append(audio)

        let chunks = framer.takeFullChunks()

        XCTAssertEqual(chunks, [audio.subdata(in: 0..<4_800), audio.subdata(in: 4_800..<9_600)])
        XCTAssertEqual(framer.takeAll(), [audio.subdata(in: 9_600..<10_000) + Data(count: 2_000)])
        XCTAssertTrue(framer.isEmpty)
    }

    func testTakeAll_sendsARemainderAboveTheMinimumUnpadded() {
        var framer = LivePCMChunkFramer(sampleRate: 24_000)
        let audio = Data(repeating: 7, count: 3_000)
        framer.append(audio)

        XCTAssertEqual(framer.takeAll(), [audio])
        XCTAssertEqual(framer.takeAll(), [])
    }

    func testReset_dropsPendingAudio() {
        var framer = LivePCMChunkFramer(sampleRate: 24_000)
        framer.append(Data(count: 100))
        framer.reset()
        XCTAssertEqual(framer.takeAll(), [])
    }
}
