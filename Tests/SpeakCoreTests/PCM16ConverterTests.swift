import XCTest

@testable import SpeakCore

final class PCM16ConverterTests: XCTestCase {

    func testMatchesPerSampleAppendArithmetic() {
        let samples: [Float] = [0, 1, -1, 0.5, -0.5, 1.5, -1.5, 0.000_030_5, -0.000_030_5, 0.999_9]

        let produced = samples.withUnsafeBufferPointer { buffer in
            PCM16Converter.data(from: buffer.baseAddress!, frameCount: buffer.count)
        }

        // The byte-for-byte reference: clamp to [-1, 1], scale by Int16.max,
        // append little-endian. This is the loop the streaming providers used
        // to run per sample.
        var expected = Data()
        expected.reserveCapacity(samples.count * 2)
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let value = Int16(clamped * Float(Int16.max))
            withUnsafeBytes(of: value.littleEndian) { expected.append(contentsOf: $0) }
        }

        XCTAssertEqual(produced.count, samples.count * 2)
        XCTAssertEqual(produced, expected)
    }

    func testEmptyInputProducesEmptyData() {
        let samples: [Float] = []
        let produced = samples.withUnsafeBufferPointer { buffer -> Data in
            guard let base = buffer.baseAddress else { return PCM16Converter.data(from: [0], frameCount: 0) }
            return PCM16Converter.data(from: base, frameCount: 0)
        }
        XCTAssertTrue(produced.isEmpty)
    }
}
