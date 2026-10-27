import Foundation
import XCTest

@testable import SpeakApp

final class TTSProgressivePCMConversionTests: XCTestCase {
    func testActualSchedulingConversionPreservesExtremaZeroEndianAndOrder() throws {
        let bytes = Data([0, 128, 255, 255, 0, 0, 1, 0, 0, 64, 255, 127])
        let samples = try XCTUnwrap(TTSProgressivePCMConversion.samples(from: bytes))
        let expected: [Float] = [-1, -1 / 32_768, 0, 1 / 32_768, 0.5, 32_767 / 32_768]
        XCTAssertEqual(samples, expected)
        XCTAssertEqual(samples.count, bytes.count / 2)
        XCTAssertTrue(samples.allSatisfy { $0 >= -1 && $0 < 1 })
    }

    func testIncompleteOrEmptySamplePayloadCannotBeScheduled() {
        XCTAssertNil(TTSProgressivePCMConversion.samples(from: Data()))
        XCTAssertNil(TTSProgressivePCMConversion.samples(from: Data([1])))
        XCTAssertNil(TTSProgressivePCMConversion.samples(from: Data([0, 0, 1])))
    }

    func testUnalignedDataSliceUsesTheSameLittleEndianContract() {
        let storage = Data([99, 0, 128, 255, 127, 88])
        let expected: [Float] = [-1, Float(32_767) / 32_768]
        XCTAssertEqual(TTSProgressivePCMConversion.samples(from: storage[1..<5]), expected)
    }
}
