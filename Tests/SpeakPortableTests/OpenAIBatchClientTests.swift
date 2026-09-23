import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakCore
import SpeakTestSupport
import XCTest

final class OpenAIBatchClientTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testWindowsWAV_UsesCanonicalModelAndLanguageContract() async throws {
        let url = try audioFile()
        defer { try? FileManager.default.removeItem(at: url) }
        StubURLProtocol.respond { request in
            let response = try XCTUnwrap(HTTPURLResponse(
                url: XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil
            ))
            return (response, Data(#"{"text":"Hello Windows"}"#.utf8))
        }
        let result = try await client(duration: 2).transcribeFile(
            at: url, apiKey: "test-only", model: OpenAITranscriptionModels.gptTranscribeCatalogID, language: "en_GB"
        )
        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        // Multipart includes binary WAV bytes; decode lossily to inspect only its text fields.
        // swiftlint:disable:next optional_data_string_conversion
        let body = String(decoding: StubURLProtocol.body(of: request), as: UTF8.self)
        XCTAssertTrue(body.contains("Content-Type: audio/wav"))
        XCTAssertTrue(body.contains("name=\"languages[]\""))
        XCTAssertTrue(body.contains("\r\nen\r\n"))
        XCTAssertTrue(body.contains("\r\ngpt-transcribe\r\n"))
        XCTAssertEqual(result.text, "Hello Windows")
        XCTAssertEqual(result.duration, 2)
        XCTAssertEqual(result.segments.first?.endTime, 2)
    }

    func testDiarisation_PreservesSpeakersAndServerDuration() async throws {
        let url = try audioFile()
        defer { try? FileManager.default.removeItem(at: url) }
        StubURLProtocol.respond { request in
            let response = try XCTUnwrap(HTTPURLResponse(
                url: XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil
            ))
            let body = #"{"duration":3,"segments":[{"start":0,"end":2,"text":"Hello","speaker":"speaker_0"}]}"#
            return (response, Data(body.utf8))
        }
        let result = try await client(duration: 99).transcribeFile(
            at: url, apiKey: "test-only", model: "openai/gpt-4o-transcribe-diarize", language: nil
        )
        XCTAssertEqual(result.text, "Speaker 1: Hello")
        XCTAssertEqual(result.duration, 3)
        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        // Multipart includes binary WAV bytes; decode lossily to inspect only its text fields.
        // swiftlint:disable:next optional_data_string_conversion
        let body = String(decoding: StubURLProtocol.body(of: request), as: UTF8.self)
        XCTAssertTrue(body.contains("diarized_json"))
        XCTAssertTrue(body.contains("chunking_strategy"))
    }

    func testHTTPFailure_PreservesExistingProviderError() async throws {
        let url = try audioFile()
        defer { try? FileManager.default.removeItem(at: url) }
        StubURLProtocol.respond { request in
            let response = try XCTUnwrap(HTTPURLResponse(
                url: XCTUnwrap(request.url), statusCode: 429, httpVersion: nil, headerFields: nil
            ))
            return (response, Data("rate limit".utf8))
        }
        do {
            _ = try await client(duration: 1).transcribeFile(
                at: url, apiKey: "test-only", model: "openai/whisper-1", language: nil
            )
            XCTFail("Expected the HTTP error")
        } catch {
            XCTAssertEqual(error as? TranscriptionProviderError, .httpError(429, "rate limit"))
        }
    }

    private func client(duration: TimeInterval) -> OpenAIBatchClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return OpenAIBatchClient(session: URLSession(configuration: configuration), durationResolver: { _ in duration })
    }

    private func audioFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try XCTUnwrap(PCMWaveWriter.wavData(pcm: Data([0, 0]), sampleRate: 16_000)).write(to: url)
        return url
    }
}
