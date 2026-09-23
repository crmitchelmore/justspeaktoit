import Foundation
import XCTest
@testable import SpeakCore

final class AssemblyAIPCMFramerTests: XCTestCase {
    func testSmallInputsCoalesceAndLargeInputsSplitWithExactFidelity() {
        var framer = AssemblyAIPCMFramer(sampleRate: 16_000)
        let source = Data((0..<10_004).map { UInt8($0 % 251) })
        var frames: [Data] = []
        frames += framer.append(source.prefix(18))
        XCTAssertTrue(frames.isEmpty)
        frames += framer.append(source.dropFirst(18))
        XCTAssertEqual(frames.map(\.count), [3200, 3200, 3200])
        XCTAssertEqual(frames.reduce(Data(), +), source.prefix(9600))
        let tail = framer.finish()
        XCTAssertEqual(tail?.count, 1600)
        XCTAssertEqual(tail?.prefix(404), source.suffix(404))
        XCTAssertTrue(tail?.dropFirst(404).allSatisfy { $0 == 0 } ?? false)
        XCTAssertNil(framer.finish())
    }

    func testEmptyInputAndResetNeverCreateAnAudioFrame() {
        var framer = AssemblyAIPCMFramer(sampleRate: 16_000)
        XCTAssertTrue(framer.append(Data()).isEmpty)
        XCTAssertNil(framer.finish())
        XCTAssertTrue(framer.append(Data([1, 2])).isEmpty)
        framer.reset()
        XCTAssertEqual(framer.bufferedByteCount, 0)
        XCTAssertNil(framer.finish())
    }

    func testAlternateRatesKeepFiftyMillisecondMinimumAndHundredMillisecondPreferredFrames() {
        for rate in [8_000, 16_000, 24_000, 44_100, 48_000] {
            var framer = AssemblyAIPCMFramer(sampleRate: rate)
            let frame = Data(repeating: 13, count: rate / 10 * 2)
            XCTAssertEqual(framer.append(frame), [frame])
            XCTAssertEqual(framer.bufferedByteCount, 0)
            XCTAssertTrue(framer.append(Data([1, 2])).isEmpty)
            XCTAssertEqual(framer.finish()?.count, (rate + 19) / 20 * 2)
        }
    }
}
