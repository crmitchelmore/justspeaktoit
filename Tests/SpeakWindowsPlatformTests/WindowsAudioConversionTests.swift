import Foundation
import SpeakCore
import CWindowsSupport
import XCTest
@testable import SpeakWindowsPlatform

final class WindowsAudioConversionTests: XCTestCase {
    func testCompressedAACImportDecodesNonSilentAudioAndPreservesOriginal() async throws {
        try await assertCompressedImport(fixture: "tone-aac", extension: "m4a")
    }

    func testCompressedMP3ImportDecodesNonSilentAudioAndPreservesOriginal() async throws {
        try await assertCompressedImport(fixture: "tone-mp3", extension: "mp3")
    }

    private func assertCompressedImport(fixture: String, extension fileExtension: String) async throws {
        let directory = try privateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let resource = try XCTUnwrap(Bundle.module.url(
            forResource: fixture, withExtension: fileExtension, subdirectory: "Fixtures"
        ))
        let input = directory.appendingPathComponent("original.\(fileExtension)")
        let output = directory.appendingPathComponent("decoded.wav")
        let original = try Data(contentsOf: resource)
        try original.write(to: input)
        let result = try await WindowsAudioConversion.convert(input: input, output: output)
        // Codec priming and trailing frames may extend the 250 ms fixture.
        XCTAssertGreaterThan(result.duration, 0.2)
        XCTAssertLessThan(result.duration, 0.4)
        XCTAssertEqual(try NativePCM16WAVReader.canonicalDuration(at: output), result.duration, accuracy: 1e-9)
        let decoded = try Data(contentsOf: output)
        XCTAssertEqual(decoded.count, 44 + Int(result.sampleCount) * 2)
        let samples = decoded.dropFirst(44)
        var squareSum = 0.0
        for offset in stride(from: 0, to: samples.count, by: 2) {
            let index = samples.startIndex + offset
            let sample = Int16(bitPattern: UInt16(samples[index]) | UInt16(samples[index + 1]) << 8)
            let normalised = Double(sample) / Double(Int16.max)
            squareSum += normalised * normalised
        }
        let rms = sqrt(squareSum / Double(result.sampleCount))
        XCTAssertGreaterThan(rms, 0.01, "Compressed audio must not decode to silence")
        XCTAssertLessThan(rms, 0.2, "Decoding must preserve the low-amplitude fixture without clipping")
        XCTAssertEqual(try Data(contentsOf: input), original)
        try FileManager.default.removeItem(at: output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testConversionReturnsCompleteCanonicalFileAndPreservesSource() async throws {
        let directory = try privateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("stereo.wav")
        let output = directory.appendingPathComponent("converted.wav")
        // One tenth of a second of 48 kHz stereo PCM, including signed samples.
        let source = try XCTUnwrap(PCMWaveWriter.wavData(
            pcm: Data(repeating: 37, count: 4_800 * 2 * 2), sampleRate: 48_000, channels: 2
        ))
        try source.write(to: input)
        let result = try await WindowsAudioConversion.convert(input: input, output: output)
        XCTAssertGreaterThan(result.sampleCount, 0)
        XCTAssertEqual(result.duration, 0.1, accuracy: 0.005)
        XCTAssertEqual(try NativePCM16WAVReader.canonicalDuration(at: output), result.duration, accuracy: 1e-9)
        XCTAssertEqual(try Data(contentsOf: input), source)
        // Returning must join the worker and release every output handle.
        try FileManager.default.removeItem(at: output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testExistingOutputIsNeverOverwrittenOrDeleted() async throws {
        let directory = try privateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("input.wav")
        let output = directory.appendingPathComponent("existing.wav")
        try XCTUnwrap(PCMWaveWriter.wavData(pcm: Data([1, 0, 2, 0]), sampleRate: 16_000)).write(to: input)
        let original = Data("Existing output must survive".utf8)
        try original.write(to: output)
        do {
            _ = try await WindowsAudioConversion.convert(input: input, output: output)
            XCTFail("Expected exclusive output creation to fail")
        } catch { XCTAssertFalse(error is CancellationError) }
        XCTAssertEqual(try Data(contentsOf: output), original)
    }

    func testCancelledBeforeStartCreatesNoOutput() async throws {
        let directory = try privateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("input.wav")
        let output = directory.appendingPathComponent("cancelled.wav")
        try XCTUnwrap(PCMWaveWriter.wavData(pcm: Data([1, 0]), sampleRate: 16_000)).write(to: input)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await WindowsAudioConversion.convert(input: input, output: output)
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testDecodeFailureRemovesPartialOutputAndRetainsSource() async throws {
        let directory = try privateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("invalid.wav")
        let output = directory.appendingPathComponent("partial.wav")
        let source = Data("Not a WAV recording".utf8)
        try source.write(to: input)
        do {
            _ = try await WindowsAudioConversion.convert(input: input, output: output)
            XCTFail("Expected invalid audio to fail")
        } catch { XCTAssertFalse(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(try Data(contentsOf: input), source)
    }

    func testCancellationDuringDecodeOrCompletionRetainsClearFileOwnership() async throws {
        let directory = try privateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("long.wav")
        let source = try XCTUnwrap(PCMWaveWriter.wavData(
            pcm: Data(repeating: 19, count: 16_000 * 2 * 600), sampleRate: 16_000
        ))
        try source.write(to: input)
        for delay in [1, 5, 20] {
            let output = directory.appendingPathComponent("cancel-\(delay).wav")
            let task = Task { try await WindowsAudioConversion.convert(input: input, output: output) }
            try await Task.sleep(for: .milliseconds(delay))
            task.cancel()
            do {
                let completed = try await task.value
                // Success may win the cancellation race. Ownership then moves
                // to this caller, including the responsibility to remove it.
                let duration = try NativePCM16WAVReader.canonicalDuration(at: output)
                XCTAssertEqual(duration, completed.duration, accuracy: 1e-9)
                try FileManager.default.removeItem(at: output)
            } catch { XCTAssertTrue(error is CancellationError, "Unexpected decode failure: \(error)") }
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
        XCTAssertEqual(try Data(contentsOf: input), source)
    }

    private func privateDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var error = [CChar](repeating: 0, count: 1_024)
        let status = directory.path.withCString { jsti_private_directory_prepare($0, &error, error.count) }
        guard status == 0 else { throw WindowsAudioConversionError(String(cString: error)) }
        return directory
    }
}
