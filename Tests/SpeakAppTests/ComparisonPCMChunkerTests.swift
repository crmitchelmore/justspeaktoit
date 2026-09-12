import Foundation
import XCTest

@testable import SpeakApp

final class ComparisonPCMChunkerTests: XCTestCase {
    func testShortInputAndConverterTailAreBufferedAndPaddedWithoutLosingAudio() {
        let chunker = ComparisonPCMChunker(sampleRate: 16_000)
        var packets: [Data] = []
        let audio = Data(repeating: 7, count: 3_400)
        for offset in stride(from: 0, to: audio.count, by: 100) {
            chunker.append(audio.subdata(in: offset..<min(offset + 100, audio.count))) { packets.append($0) }
        }
        chunker.finish { packets.append($0) }
        XCTAssertEqual(packets.map(\.count), [3_200, 1_600])
        let sent = packets.reduce(into: Data()) { $0.append($1) }
        XCTAssertEqual(Data(sent.prefix(audio.count)), audio)
        XCTAssertTrue(sent.dropFirst(audio.count).allSatisfy { $0 == 0 })
        chunker.finish { _ in XCTFail("The tail must only be sent once") }
    }

    func testOversizedInputIsSplitIntoBoundedPackets() {
        let chunker = ComparisonPCMChunker(sampleRate: 48_000)
        var packets: [Data] = []
        chunker.append(Data(repeating: 1, count: 192_000)) { packets.append($0) }
        chunker.finish { packets.append($0) }
        XCTAssertEqual(packets.count, 20)
        XCTAssertTrue(packets.allSatisfy { $0.count == 9_600 })
    }
}
