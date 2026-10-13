import AVFoundation
import Foundation
import SpeakTestSupport
import XCTest
@testable import SpeakCore

final class InklingAudioPreparationTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testEncodedStereoAudioBecomesMono16kHzWAVWithoutChangingTheRecording() async throws {
        let source = try Self.recording()
        defer { try? FileManager.default.removeItem(at: source) }
        let original = try Data(contentsOf: source)
        let canonical = try await NativePCM16WAVReader.prepareWAV(
            at: source, maximumDuration: 20 * 60, maximumBytes: 50 * 1024 * 1024
        )
        let wav = source.deletingPathExtension().appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        try canonical.data.write(to: wav)
        XCTAssertEqual(try NativePCM16WAVReader.canonicalDuration(at: wav), canonical.duration, accuracy: 0.0001)
        XCTAssertEqual(canonical.duration, 1, accuracy: 0.05)

        for model in OpenRouterInlineAudioTranscriptionClient.batchCatalogIDs
            where OpenRouterInlineAudioTranscriptionClient.requiresCanonicalPCM16WAV(model: model) {
            StubURLProtocol.handler = { request in
                XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/chat/completions")
                let body = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: StubURLProtocol.body(of: request)) as? [String: Any]
                )
                XCTAssertEqual(body["model"] as? String, model)
                let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
                let content = try XCTUnwrap(messages[0]["content"] as? [[String: Any]])
                let audio = try XCTUnwrap(content[1]["input_audio"] as? [String: String])
                XCTAssertEqual(audio["format"], "wav")
                XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(audio["data"])), canonical.data)
                return .ok(Data(#"{"choices":[{"message":{"content":"Recorded words"}}]}"#.utf8), url: request.url!)
            }
            let result = try await OpenRouterInlineAudioTranscriptionClient(
                apiKey: "test-key", session: StubURLProtocol.makeSession()
            ).transcribeFile(at: source, model: model, language: nil)
            XCTAssertEqual(result.text, "Recorded words")
        }
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testDecodedAudioLimitAndCancellationFailBeforeUpload() async throws {
        let source = try Self.recording(seconds: 4)
        defer { try? FileManager.default.removeItem(at: source) }
        StubURLProtocol.handler = { _ in
            XCTFail("Invalid audio must not reach the service")
            return .ok(Data())
        }
        do {
            _ = try await NativePCM16WAVReader.prepareWAV(
                at: source, maximumDuration: 0.1, maximumBytes: 50 * 1024 * 1024
            )
            XCTFail("Expected duration rejection")
        } catch NativePCM16WAVReader.PreparationError.limitExceeded {}
        let client = OpenRouterInlineAudioTranscriptionClient(
            apiKey: "test-key", session: StubURLProtocol.makeSession(),
            maximumInlineAudioBytes: Int64(try Data(contentsOf: source).count) + 1
        )
        do {
            _ = try await client.transcribeFile(at: source, model: "thinkingmachines/inkling", language: nil)
            XCTFail("Expected decoded size rejection")
        } catch OpenRouterInlineAudioTranscriptionClient.InputError.inklingAudioLimit {}
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.transcribeFile(at: source, model: "thinkingmachines/inkling", language: nil)
        }
        do {
            _ = try await cancelled.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
    }

    private static func recording(seconds: Int = 1) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false
        ))
        let frames = 48_000 * seconds
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let samples = try XCTUnwrap(buffer.floatChannelData)
        for channel in 0..<2 {
            for frame in 0..<frames {
                samples[channel][frame] = Float(sin(Double(frame) * 2 * .pi * 440 / 48_000)) * 0.25
            }
        }
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 96_000
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
        return url
    }
}
