import Foundation
import XCTest
import SpeakCore

final class VoiceGeneratedAudioTests: XCTestCase {
    func testGeneratedAudio_ValidatesExactNativeFormatAndDuration() throws {
        let wav = try XCTUnwrap(PCMWaveWriter.wavData(pcm: Data([1, 0, 2, 0]), sampleRate: 24_000))
        let result = try VoiceGeneratedAudio(validating: wav)
        XCTAssertEqual(result.wav, wav)
        XCTAssertEqual(result.sampleRate, 24_000)
        XCTAssertEqual(result.duration, 2.0 / 24_000, accuracy: 0.000001)
        XCTAssertThrowsError(try VoiceGeneratedAudio(validating: Data()))
        XCTAssertThrowsError(try VoiceGeneratedAudio(validating: Data("not audio".utf8)))
        let wrongRate = try XCTUnwrap(PCMWaveWriter.wavData(pcm: Data([1, 0, 2, 0]), sampleRate: 16_000))
        XCTAssertThrowsError(try VoiceGeneratedAudio(validating: wrongRate))
    }

    func testExplicitSourceRate_PreservesSixteenKilohertzWithoutRelabellingOtherAudio() throws {
        let pcm = Data([1, 0, 2, 0])
        let wav = try XCTUnwrap(PCMWaveWriter.wavData(pcm: pcm, sampleRate: 16_000))
        let result = try VoiceGeneratedAudio(validating: wav, sampleRate: 16_000)
        XCTAssertEqual(result.wav, wav)
        XCTAssertEqual(result.sampleRate, 16_000)
        XCTAssertEqual(result.duration, 2.0 / 16_000, accuracy: 0.000001)
        let other = try XCTUnwrap(PCMWaveWriter.wavData(pcm: pcm, sampleRate: 24_000))
        XCTAssertThrowsError(try VoiceGeneratedAudio(validating: other, sampleRate: 16_000))
        for rate in [8_000, 32_000, 48_000] {
            let unsupported = try XCTUnwrap(PCMWaveWriter.wavData(pcm: pcm, sampleRate: rate))
            XCTAssertThrowsError(try VoiceGeneratedAudio(validating: unsupported, sampleRate: rate))
        }
    }

}
