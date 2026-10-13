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

}
