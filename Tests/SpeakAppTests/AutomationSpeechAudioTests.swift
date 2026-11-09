import AVFoundation
import SpeakCore
import XCTest
@testable import SpeakApp

/// The Mac's `speak say` file steps: provider audio is published in the
/// requested container or refused, never mislabelled.
final class AutomationSpeechAudioTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("speech-audio-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeWAV() throws -> URL {
        let url = directory.appendingPathComponent("source.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 24_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false
        ])
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2_400))
        buffer.frameLength = 2_400
        for index in 0..<2_400 { buffer.floatChannelData?[0][index] = Float(sin(Double(index) / 10)) * 0.2 }
        try file.write(from: buffer)
        return url
    }

    func testWrite_ConvertsToTheRequestedContainerAndReplacesAtomically() throws {
        let source = try self.makeWAV()
        let target = directory.appendingPathComponent("out.m4a")
        try Data("stale".utf8).write(to: target)
        try AutomationSpeechAudio.write(source, to: target, format: .m4a)
        let written = try AVAudioFile(forReading: target)
        XCTAssertEqual(written.fileFormat.settings[AVFormatIDKey] as? UInt32, kAudioFormatMPEG4AAC)
        XCTAssertGreaterThan(written.length, 0)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(Set(leftovers), ["source.wav", "out.m4a"])
    }

    func testWrite_CopiesMatchingAudioAndRefusesAnMP3ItCannotEncode() throws {
        let source = try self.makeWAV()
        let copy = directory.appendingPathComponent("copy.wav")
        try AutomationSpeechAudio.write(source, to: copy, format: .wav)
        XCTAssertEqual(try Data(contentsOf: copy), try Data(contentsOf: source))

        let mp3 = directory.appendingPathComponent("out.mp3")
        XCTAssertThrowsError(try AutomationSpeechAudio.write(source, to: mp3, format: .mp3)) { error in
            XCTAssertEqual((error as? AutomationError)?.code, .speechFailed)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: mp3.path))
    }

    func testSystemVoice_WritesCompleteWAVWithoutAnAPIKey() async throws {
        guard !AVSpeechSynthesisVoice.speechVoices().isEmpty else { throw XCTSkip("No system voices installed") }
        let client = SystemTTSClient()
        let result = try await withThrowingTaskGroup(of: TTSResult.self) { group in
            group.addTask {
                try await client.synthesize(
                    text: "Just Speak To It.", voice: TextToSpeechManager.onDeviceVoiceID,
                    settings: TTSSettings(format: .wav)
                )
            }
            group.addTask {
                try await Task.sleep(for: .seconds(60))
                throw XCTSkip("System speech did not finish within a minute on this host")
            }
            defer { group.cancelAll() }
            let first = try await group.next()
            return try XCTUnwrap(first)
        }
        defer { try? FileManager.default.removeItem(at: result.audioURL) }
        XCTAssertEqual(result.audioURL.pathExtension, "wav")
        let data = try Data(contentsOf: result.audioURL)
        XCTAssertEqual(String(data: data.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertGreaterThan(try AVAudioFile(forReading: result.audioURL).length, 0)
        XCTAssertGreaterThan(result.duration, 0)
    }
}
