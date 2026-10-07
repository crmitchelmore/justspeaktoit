import Foundation
import XCTest
import SpeakCore
import SpeakLinuxPlatform

/// GStreamer import conversion on real files: a 44.1 kHz stereo WAV becomes
/// canonical 16 kHz mono PCM16 with the same duration and a live signal.
final class LinuxAudioConversionTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("conversion-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    /// A 1 s, 440 Hz, 44.1 kHz stereo PCM16 WAV.
    private func stereoWave() throws -> URL {
        let rate = 44_100
        var pcm = Data()
        for index in 0..<rate {
            let value = Int16(10_000 * sin(Double(index) * 2 * .pi * 440 / Double(rate)))
            for _ in 0..<2 { withUnsafeBytes(of: value.littleEndian) { pcm.append(contentsOf: $0) } }
        }
        var header = Data("RIFF".utf8)
        func u32(_ value: Int) { withUnsafeBytes(of: UInt32(value).littleEndian) { header.append(contentsOf: $0) } }
        func u16(_ value: Int) { withUnsafeBytes(of: UInt16(value).littleEndian) { header.append(contentsOf: $0) } }
        u32(36 + pcm.count)
        header.append(Data("WAVEfmt ".utf8))
        u32(16); u16(1); u16(2); u32(rate); u32(rate * 4); u16(4); u16(16)
        header.append(Data("data".utf8))
        u32(pcm.count)
        let url = directory.appendingPathComponent("stereo.wav")
        try (header + pcm).write(to: url)
        return url
    }

    func testStereoWAVBecomesCanonicalMono16kHz() async throws {
        let output = directory.appendingPathComponent("converted.wav")
        let duration = try await LinuxAudioConversion.convert(input: try stereoWave(), output: output)
        XCTAssertEqual(duration, 1, accuracy: 0.02)
        XCTAssertEqual(try NativePCM16WAVReader.canonicalDuration(at: output) ?? 0, duration, accuracy: 0.001)
        let data = try Data(contentsOf: output)
        let samples = data.dropFirst(44).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        XCTAssertGreaterThan(samples.map { abs(Int($0)) }.max() ?? 0, 5_000, "the tone was lost")
        let mode = try FileManager.default.attributesOfItem(atPath: output.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testUndecodableInputLeavesNoOutput() async throws {
        let input = directory.appendingPathComponent("noise.mp3")
        try Data((0..<4_096).map { UInt8(truncatingIfNeeded: $0 &* 31) }).write(to: input)
        let output = directory.appendingPathComponent("converted.wav")
        do {
            _ = try await LinuxAudioConversion.convert(input: input, output: output)
            XCTFail("Random bytes should not decode")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testAnExistingOutputIsNeverReplaced() async throws {
        let output = directory.appendingPathComponent("converted.wav")
        try Data("keep".utf8).write(to: output)
        do {
            _ = try await LinuxAudioConversion.convert(input: try stereoWave(), output: output)
            XCTFail("An existing output must not be overwritten")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: output), Data("keep".utf8))
    }
}
