import Foundation
import XCTest

@testable import SpeakCore

final class MP3FrameBoundaryValidatorTests: XCTestCase {
    func testArbitraryFragmentsPreserveID3AndCompleteFrameBoundaries() throws {
        let frame = Self.frame()
        let bytes = Data([73, 68, 51, 4, 0, 0, 0, 0, 0, 3, 1, 2, 3]) + frame + frame
        for size in [1, 2, 7, 100, 1024] {
            var validator = MP3FrameBoundaryValidator()
            for start in stride(from: 0, to: bytes.count, by: size) {
                try validator.append(bytes.subdata(in: start..<min(start + size, bytes.count)))
            }
            try validator.finish()
            XCTAssertEqual(validator.frameCount, 2)
        }
    }

    func testEveryKnownIncompleteFinalFrameIsRejectedAtEOF() throws {
        let frame = Self.frame()
        for removed in [1, 2, 3, frame.count - 1] {
            var validator = MP3FrameBoundaryValidator()
            try validator.append(frame + frame.dropLast(removed))
            XCTAssertThrowsError(try validator.finish(), "Missing \(removed) bytes must not become file fallback")
        }
    }

    func testIncompleteOrOversizedMetadataDoesNotBecomeAnEmptySuccess() throws {
        for prefix in [Data("ID".utf8), Data([73, 68, 51, 4, 0, 0, 0, 0, 0, 4, 1, 2])] {
            var validator = MP3FrameBoundaryValidator()
            try validator.append(prefix)
            XCTAssertThrowsError(try validator.finish())
        }
        var oversized = MP3FrameBoundaryValidator()
        XCTAssertThrowsError(try oversized.append(Data([73, 68, 51, 4, 0, 0, 0, 32, 0, 0]))) {
            XCTAssertEqual($0 as? OpenRouterAudioError, .responseTooLarge)
        }
    }

    func testInvalidHeadersAndOversizedObserverChunksAreRefused() {
        for header in [[UInt8](repeating: 0, count: 4), [255, 255, 148, 0], [255, 251, 4, 0]] {
            var validator = MP3FrameBoundaryValidator()
            XCTAssertThrowsError(try validator.append(Data(header)))
        }
        var validator = MP3FrameBoundaryValidator()
        XCTAssertThrowsError(try validator.append(Data(repeating: 0, count: 1025)))
    }

    func testCompleteID3v1TrailerIsAllowedButPartialTrailerAndTrailingJunkFail() throws {
        let frame = Self.frame()
        let trailer = Data("TAG".utf8) + Data(repeating: 0, count: 125)
        var valid = MP3FrameBoundaryValidator()
        try valid.append(frame + trailer)
        try valid.finish()
        for suffix in [trailer.dropLast(), Data([0, 1, 2, 3])] {
            var invalid = MP3FrameBoundaryValidator()
            do {
                try invalid.append(frame + suffix)
                try invalid.finish()
                XCTFail("An incomplete trailer or trailing junk must fail")
            } catch {
                XCTAssertEqual(error as? OpenRouterAudioError, .invalidResponse)
            }
        }
    }

    func testBitrateAndPaddingMayVaryWithoutChangingStreamFormat() throws {
        // Joint stereo differs from the first frame's stereo mode, but keeps
        // the same two-channel format; only bitrate/padding change frame size.
        let variableBitrateFrame = Data([255, 251, 150, 64]) + Data(repeating: 0, count: 381)
        var validator = MP3FrameBoundaryValidator()
        try validator.append(Self.frame())
        try validator.append(variableBitrateFrame)
        try validator.finish()
        XCTAssertEqual(validator.frameCount, 2)
    }

    func testSampleRateMPEGVersionAndChannelCountCannotChangeBetweenFrames() throws {
        let changed = [
            Data([255, 251, 112, 0]) + Data(repeating: 0, count: 309), // 44.1 kHz
            Data([255, 243, 116, 0]) + Data(repeating: 0, count: 164), // MPEG-2/24 kHz
            Data([255, 251, 116, 192]) + Data(repeating: 0, count: 284) // mono
        ]
        for frame in changed {
            var validator = MP3FrameBoundaryValidator()
            try validator.append(Self.frame())
            XCTAssertThrowsError(try validator.append(frame))
        }
    }

    // A syntactically complete MPEG-1 Layer III 48 kHz/96 kbps frame. Its zero
    // payload tests framing only; it is deliberately not a native decode fixture.
    private static func frame() -> Data {
        Data([255, 251, 116, 0]) + Data(repeating: 0, count: 284)
    }
}
