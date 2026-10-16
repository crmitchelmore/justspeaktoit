import Foundation
import XCTest
import SpeakCore

final class VoiceGeneratedAudioTests: XCTestCase {
    func testGeneratedAudio_ValidatesExactNativeFormatAndDuration() throws {
        let wav = try XCTUnwrap(PCMWaveWriter.wavData(pcm: Data([1, 0, 2, 0]), sampleRate: 24_000))
        let result = try VoiceGeneratedAudio(validating: wav)
        XCTAssertEqual(result.wav, wav)
        XCTAssertEqual(result.duration, 2.0 / 24_000, accuracy: 0.000001)
        XCTAssertThrowsError(try VoiceGeneratedAudio(validating: Data()))
        XCTAssertThrowsError(try VoiceGeneratedAudio(validating: Data("not audio".utf8)))
        let wrongRate = try XCTUnwrap(PCMWaveWriter.wavData(pcm: Data([1, 0, 2, 0]), sampleRate: 16_000))
        XCTAssertThrowsError(try VoiceGeneratedAudio(validating: wrongRate))
    }

    func testCanonicalQualityRates_AdmitRealPCMWhileRejectingMismatchAndUnsupportedRates() throws {
        for quality in VoiceSynthesisQuality.allCases {
            let rate = quality.sampleRate
            let wav = try XCTUnwrap(PCMWaveWriter.wavData(pcm: Data([1, 0, 2, 0]), sampleRate: rate))
            let result = try VoiceGeneratedAudio(validating: wav, sampleRate: rate)
            XCTAssertEqual(result.wav, wav)
            XCTAssertEqual(result.sampleRate, rate)
            XCTAssertEqual(result.duration, 2.0 / Double(rate), accuracy: 0.000001)
            let other = rate == 24_000 ? 48_000 : 24_000
            XCTAssertThrowsError(try VoiceGeneratedAudio(validating: wav, sampleRate: other))
        }
        for rate in [8_000, 22_050, 32_000, 44_100, 96_000] {
            let wav = try XCTUnwrap(PCMWaveWriter.wavData(pcm: Data([1, 0, 2, 0]), sampleRate: rate))
            XCTAssertThrowsError(try VoiceGeneratedAudio(validating: wav, sampleRate: rate))
        }
    }

}
