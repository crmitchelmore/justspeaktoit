import AVFoundation
import XCTest

@testable import SpeakCore

/// The shared Apple live PCM path: one tap copy, one retained conversion to
/// PCM16 mono, and its end-of-stream tail.
final class LivePCM16ConversionTests: XCTestCase {
    private func format(_ rate: Double) throws -> AVAudioFormat {
        try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
    }

    private func pcm16(_ rate: Double) throws -> AVAudioFormat {
        try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate, channels: 1, interleaved: true))
    }

    private func tone(_ format: AVAudioFormat, frames: AVAudioFrameCount, start: Int) throws -> AVAudioPCMBuffer {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        let samples = try XCTUnwrap(buffer.floatChannelData)
        buffer.frameLength = frames
        for index in 0..<Int(frames) {
            samples[0][index] = Float(0.25 * sin(2 * Double.pi * 220 * Double(start + index) / format.sampleRate))
        }
        return buffer
    }

    func testRetainedConversionPlusTailCoversTheWholeResampledRecording() throws {
        let input = try format(48_000), output = try pcm16(16_000)
        let conversion = LivePCM16Conversion()
        var bytes = 0
        for chunk in 0..<10 {
            bytes += try conversion.pcm16(from: tone(input, frames: 4_096, start: chunk * 4_096), to: output).count
        }
        let tail = try XCTUnwrap(conversion.drainPCM16(), "The resampler still holds the last frames")
        bytes += tail.count
        XCTAssertEqual(Double(bytes / 2), 40_960.0 / 3, accuracy: 2, "Every input frame reaches the provider once")
        XCTAssertNil(conversion.drainPCM16(), "A drained converter is released")
    }

    func testPrepare_refusesAnImpossibleConversionBeforeTheFirstChunk() throws {
        let input = try format(48_000)
        let conversion = LivePCM16Conversion()
        let mp3 = try XCTUnwrap(AVAudioFormat(settings: [
            AVFormatIDKey: kAudioFormatMPEGLayer3, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1
        ]))
        XCTAssertFalse(conversion.prepare(from: input, to: mp3), "No Apple converter encodes MP3")
        XCTAssertTrue(conversion.prepare(from: input, to: try pcm16(16_000)))
    }

    func testResetDropsTheConverterWithoutAnyTail() throws {
        let conversion = LivePCM16Conversion()
        _ = try conversion.pcm16(from: tone(format(48_000), frames: 1_024, start: 0), to: pcm16(16_000))
        conversion.reset()
        XCTAssertNil(conversion.drainPCM16())
    }

    func testCopyCarriesTheSamplesAndLengthIntoAPooledBuffer() throws {
        let source = try tone(format(48_000), frames: 512, start: 0)
        let destination = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: 1_024))
        LivePCMCopy.copy(source, into: destination)
        XCTAssertEqual(destination.frameLength, 512)
        let copied = try XCTUnwrap(destination.floatChannelData)[0]
        let original = try XCTUnwrap(source.floatChannelData)[0]
        XCTAssertEqual((0..<512).map { copied[$0] }, (0..<512).map { original[$0] })
    }

    func testConversionFailuresAreTypedAndExplainThatTextIsKept() {
        let failure = LivePCMConversionError.conversionFailed(domain: NSOSStatusErrorDomain, code: -50)
        XCTAssertEqual(failure, .conversionFailed(domain: NSOSStatusErrorDomain, code: -50))
        XCTAssertNotEqual(failure, .converterUnavailable(inputSampleRate: 48_000, outputSampleRate: 16_000))
        XCTAssertTrue(failure.errorDescription?.contains("text transcribed so far is kept") ?? false)
    }
}
