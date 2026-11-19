import Foundation
import XCTest
import SpeakCore
@testable import SpeakDesktop

/// The shared Windows/Linux adapters over synthetic C function tables: status
/// mapping, buffers and borrowed contexts, without a native library.
final class DesktopNativeBridgeTests: XCTestCase {
    func testNativeStringsCopyTruncatesAndTerminates() {
        var buffer = [CChar](repeating: 7, count: 4)
        DesktopNativeStrings.copy("abcdef", into: &buffer, capacity: buffer.count)
        XCTAssertEqual(buffer, [97, 98, 99, 0])
        DesktopNativeStrings.copy("ignored", into: nil, capacity: 8)
        let strings = DesktopNativeStrings()
        XCTAssertEqual(String(cString: strings.add("é")), "é")
    }

    func testFilePublicationMapsNativeStatuses() throws {
        let source = URL(fileURLWithPath: "/synthetic/source")
        let destination = URL(fileURLWithPath: "/synthetic/destination")
        func copy(_ status: Int32) -> DesktopFilePublication.Copy {
            .native { _, _, error, capacity in
                DesktopNativeStrings.copy("native detail", into: error, capacity: capacity)
                return status
            }
        }
        XCTAssertNoThrow(try copy(0).publish(source, destination))
        XCTAssertThrowsError(try copy(2).publish(source, destination)) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertThrowsError(try copy(3).publish(source, destination)) { error in
            let failure = error as? DesktopFilePublication.CopyCompletionFailure
            XCTAssertEqual(failure?.destination, destination)
            XCTAssertEqual(failure?.detail, "native detail")
        }
        XCTAssertThrowsError(try copy(1).publish(source, destination)) { error in
            guard case .invalid(let detail)? = error as? DataMigrationError else { return XCTFail("\(error)") }
            XCTAssertEqual(detail, "native detail")
        }
    }

    func testVoiceCodecDeliversNativeOutputThroughBorrowedContext() async throws {
        // A synthetic container reaches the capture, whose validation then rejects it.
        let codec = DesktopVoiceAudioCodec(available: { _, _, _, _ in 0 }, encode: { request, _, _ in
            guard String(cString: request.format) == "mp3", request.cancelled(request.context) == 0 else { return -1 }
            let container: [UInt8] = [1, 2, 3]
            let pcm: [UInt8] = [0, 1, 0, 2]
            guard request.output(0, container, container.count, request.context) == 0,
                  request.output(1, pcm, pcm.count, request.context) == 0,
                  request.output(9, pcm, pcm.count, request.context) == -1 else { return -1 }
            return 0
        })
        let input = try VoiceGeneratedAudio(validating: try Self.wav(), sampleRate: 24_000)
        do {
            _ = try await codec.encode(input, format: .mp3)
            XCTFail("Expected the capture to validate the synthetic container")
        } catch VoiceAudioFormatError.invalidContainer {}
    }

    func testVoiceCodecReportsUnavailableReasonAndCancellation() async throws {
        let unavailable = DesktopVoiceAudioCodec(available: { _, _, error, capacity in
            DesktopNativeStrings.copy("no encoder", into: error, capacity: capacity)
            return -1
        }, encode: { _, _, _ in 1 })
        let rate = try XCTUnwrap(VoiceSynthesisQuality.allCases.first?.sampleRate)
        do {
            try await unavailable.requireAvailable(.mp3, sampleRate: rate)
            XCTFail("Expected the native reason")
        } catch VoiceAudioFormatError.unavailable(let reason) {
            XCTAssertEqual(reason, "no encoder")
        }
        try await unavailable.requireAvailable(.wav, sampleRate: rate)
        let input = try VoiceGeneratedAudio(validating: try Self.wav(sampleRate: rate), sampleRate: rate)
        do {
            _ = try await unavailable.encode(input, format: .mp3)
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
    }

    func testWhisperRuntimeMapsNativeResultsAndHasherGuardsReuse() async throws {
        let bridge = Self.syntheticBridge
        let runtime = try DesktopNativeWhisperRuntime.open(
            bridge: bridge, directory: URL(fileURLWithPath: "/synthetic/runtime"), allowGPU: false
        )
        XCTAssertEqual(runtime.description, "synthetic runtime")
        XCTAssertTrue(runtime.usesGPU)
        XCTAssertTrue(runtime.releaseModel(loadedFrom: URL(fileURLWithPath: "/synthetic/model.bin")))
        let text = try await runtime.transcribe(
            samples: [0], modelFile: URL(fileURLWithPath: "/ok"), modelSHA256: "digest", language: "en"
        )
        XCTAssertEqual(text, "transcript")
        do {
            _ = try await runtime.transcribe(
                samples: [0], modelFile: URL(fileURLWithPath: "/mismatch"), modelSHA256: "digest", language: nil
            )
            XCTFail("Expected a digest mismatch")
        } catch DesktopLocalTranscriptionError.modelDoesNotMatchDigest {}
        do {
            _ = try await runtime.transcribe(
                samples: [0], modelFile: URL(fileURLWithPath: "/failure"), modelSHA256: "digest", language: nil
            )
            XCTFail("Expected the native reason")
        } catch let error as DesktopNativeLocalTranscriptionError {
            XCTAssertEqual(error.message, "whisper failed")
        }

        let hasher = try DesktopNativeSHA256Hasher(bridge: bridge)
        try Data([1]).withUnsafeBytes { try hasher.update($0) }
        XCTAssertEqual(try hasher.finish(), "ab")
        XCTAssertThrowsError(try hasher.finish())
        XCTAssertEqual(DesktopNativeSHA256Hasher.digestProvider(bridge).name, "Synthetic SHA-256")
    }

    private static func wav(sampleRate: Int = 24_000) throws -> Data {
        try XCTUnwrap(PCMWaveWriter.wavData(pcm: Data([0, 16, 0, 32, 0, 48, 0, 64]), sampleRate: sampleRate))
    }

    private static let syntheticBridge = DesktopNativeLocalTranscriptionBridge(
        sha256Create: { _, _ in OpaquePointer(bitPattern: 0x10) },
        sha256Update: { _, _, _, _, _ in 0 },
        sha256Finish: { _, hex, capacity, _, _ in
            DesktopNativeStrings.copy("ab", into: hex, capacity: capacity)
            return 0
        },
        sha256Destroy: { _ in },
        runtimeOpen: { _, _, _, _ in OpaquePointer(bitPattern: 0x20) },
        runtimeDescribe: { _, text, capacity in
            DesktopNativeStrings.copy("synthetic runtime", into: text, capacity: capacity)
            return 0
        },
        runtimeUsesGPU: { _ in 1 },
        releaseModel: { _ in },
        releaseModelAt: { _, _ in 1 },
        jobCreate: { OpaquePointer(bitPattern: 0x30) },
        jobCancel: { _ in },
        jobDestroy: { _ in },
        transcribe: { _, path, _, _, _, _, _, _, text, error, capacity in
            switch path.map(String.init(cString:)) {
            case "/ok":
                text?.pointee = strdup("transcript")
                return 0
            case "/mismatch": return 2
            default:
                DesktopNativeStrings.copy("whisper failed", into: error, capacity: capacity)
                return -1
            }
        },
        freeText: { free($0) },
        digestName: "Synthetic SHA-256"
    )
}
