#if os(Linux)
import Foundation
import XCTest
import SpeakCore
import SpeakLinuxPlatform

final class LinuxVoiceAudioCodecTests: XCTestCase {
    func testNativeMP3At16k_RealContainerAndExactRateOrExplicitUnavailable() async throws {
        try await roundTrip(.mp3, rate: 16_000)
    }
    func testNativeMP3At24k_RealContainerAndExactRateOrExplicitUnavailable() async throws {
        try await roundTrip(.mp3, rate: 24_000)
    }
    func testNativeMP3At48k_RealContainerAndExactRateOrExplicitUnavailable() async throws {
        try await roundTrip(.mp3, rate: 48_000)
    }
    func testNativeM4AAt16k_RealContainerAndExactRateOrExplicitUnavailable() async throws {
        try await roundTrip(.m4a, rate: 16_000)
    }
    func testNativeM4AAt24k_RealContainerAndExactRateOrExplicitUnavailable() async throws {
        try await roundTrip(.m4a, rate: 24_000)
    }
    func testNativeM4AAt48k_RealContainerAndExactRateOrExplicitUnavailable() async throws {
        try await roundTrip(.m4a, rate: 48_000)
    }
    func testNativeWAV_IsLosslessAndDoesNotRequireInstalledCompressedCodecs() async throws {
        let input = try syntheticAudio(rate: 48_000)
        let output = try await LinuxVoiceAudioCodec.encode(input, format: .wav)
        XCTAssertEqual(output.data, input.data)
        XCTAssertEqual(output.wav, input.wav)
        XCTAssertEqual(output.format, .wav)
        let syntheticCompressed = try VoiceGeneratedAudio(
            encoded: Data([0xFF, 0xF3, 0x90, 0]), format: .mp3,
            decodedWAV: input.wav, sampleRate: input.sampleRate)
        do {
            _ = try await LinuxVoiceAudioCodec.encode(syntheticCompressed, format: .wav)
            XCTFail("Compressed bytes must not pass through as a WAV result.")
        } catch VoiceAudioFormatError.invalidContainer {}
        do {
            try await LinuxVoiceAudioCodec.requireAvailable(.m4a, sampleRate: -1)
            XCTFail("Invalid sample rate must refuse without an integer conversion trap.")
        } catch DeepgramSpeechError.unsupportedAudioFormat {}
    }
    func testCancelledWorker_IsAwaitedUntilItsNativeScopeHasTornDown() async throws {
        let entered = expectation(description: "Native work entered")
        let release = NSCondition()
        let state = NativeCodecScope()
        let task = Task {
            try await VoiceAudioCodecWorker.run { cancellation in
                release.lock()
                entered.fulfill()
                while !state.open { release.wait() }
                release.unlock()
                defer { state.finished = true }
                if cancellation.isCancelled { throw CancellationError() }
            }
        }
        await fulfillment(of: [entered], timeout: 10)
        task.cancel()
        release.withLock { state.open = true; release.signal() }
        do { try await task.value; XCTFail("Cancelled native worker returned success.") } catch is CancellationError {}
        XCTAssertTrue(state.finished)
    }

    private func roundTrip(_ format: VoiceAudioFormat, rate: Int) async throws {
        do { try await LinuxVoiceAudioCodec.requireAvailable(format, sampleRate: rate) } catch {
            guard case VoiceAudioFormatError.unavailable(let reason) = error, !reason.isEmpty else { throw error }
            throw XCTSkip("UNAVAILABLE \(format.rawValue), mono \(rate) Hz: \(reason)")
        }
        let input = try syntheticAudio(rate: rate)
        let output = try await LinuxVoiceAudioCodec.encode(input, format: format)
        try format.validateContainer(output.data)
        XCTAssertNotEqual(output.data.prefix(4), Data("RIFF".utf8))
        XCTAssertEqual(output.format.fileExtension, format.fileExtension)
        XCTAssertEqual(output.sampleRate, rate)
        XCTAssertEqual(output.wav[22], 1)
        XCTAssertEqual(output.wav[23], 0)
        XCTAssertGreaterThan(output.duration, 0.8)
        XCTAssertLessThan(output.duration, 1.3)
        XCTAssertTrue(output.wav.dropFirst(44).contains { $0 != 0 })
    }
    private func syntheticAudio(rate: Int) throws -> VoiceGeneratedAudio {
        var pcm = Data()
        for index in 0..<rate {
            let sample = Int16(index % 64 < 32 ? 6_000 : -6_000)
            let bits = UInt16(bitPattern: sample)
            pcm.append(UInt8(bits & 255)); pcm.append(UInt8(bits >> 8))
        }
        return try VoiceGeneratedAudio(validating: XCTUnwrap(PCMWaveWriter.wavData(pcm: pcm, sampleRate: rate)),
                                       sampleRate: rate)
    }
}

// `open` is protected by the test's condition; `finished` is observed only after awaiting its worker.
private final class NativeCodecScope: @unchecked Sendable {
    var open = false
    var finished = false
}
#endif
