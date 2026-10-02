import Foundation
import SpeakCore
import SpeakDesktop
import XCTest

final class PCMRecordingSampleRateTests: XCTestCase {
    func testBothCaptureRatesPersistExactAudioAndMeasuredDuration() throws {
        for rate in [16_000, 24_000] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
            defer { try? FileManager.default.removeItem(at: url) }
            let file = try PCMRecordingFile(url: url, sampleRate: rate)
            let pcm = Data(repeating: 23, count: rate / 5)
            try file.append(pcm)
            XCTAssertEqual(try file.finish(), 0.1, accuracy: 1e-9)
            XCTAssertEqual(file.recordingSampleRate, rate)
            XCTAssertEqual(try Data(contentsOf: url), PCMWaveWriter.wavData(pcm: pcm, sampleRate: rate))
        }
    }

    func testRecoveryUsesOwnedHeaderRateAndPreservesAudio() throws {
        for rate in [16_000, 24_000] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
            defer { try? FileManager.default.removeItem(at: url) }
            let pcm = Data(repeating: 15, count: rate / 5)
            var unfinished = try XCTUnwrap(PCMWaveWriter.wavData(pcm: Data(), sampleRate: rate))
            unfinished.append(pcm)
            try unfinished.write(to: url)
            XCTAssertEqual(try PCMRecordingFile.recoverInterruptedFile(at: url), 0.1, accuracy: 1e-9)
            XCTAssertEqual(try Data(contentsOf: url), PCMWaveWriter.wavData(pcm: pcm, sampleRate: rate))
        }
    }

    func testUnsupportedOrInconsistentRateIsRejectedWithoutChangingFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try PCMRecordingFile(url: url, sampleRate: 44_100))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        var wav = try XCTUnwrap(PCMWaveWriter.wavData(pcm: Data([1, 0]), sampleRate: 24_000))
        wav[28] = 0 // Incorrect byte rate, even though the sample rate is supported.
        try wav.write(to: url)
        XCTAssertThrowsError(try PCMRecordingFile.recoverInterruptedFile(at: url))
        XCTAssertEqual(try Data(contentsOf: url), wav)
    }
}
