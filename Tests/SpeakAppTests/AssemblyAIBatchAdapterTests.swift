import Foundation
import SpeakCore
import SpeakTestSupport
import XCTest
@testable import SpeakApp

final class AssemblyAIBatchAdapterTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testAppleAdapterRetainsNativeDurationWithTheSharedBatchTransport() async throws {
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try XCTUnwrap(PCMWaveWriter.wavData(pcm: Data(count: 8000), sampleRate: 16_000)).write(to: audio)
        defer { try? FileManager.default.removeItem(at: audio) }
        StubURLProtocol.handler = { request in
            let body: String
            switch request.url?.path {
            case "/v2/upload":
                XCTAssertNil(request.httpBody)
                body = #"{"upload_url":"https://cdn.assemblyai.com/fixture"}"#
            case "/v2/transcript":
                body = #"{"id":"job-1","status":"queued"}"#
            case "/v2/transcript/job-1":
                body = #"{"id":"job-1","status":"completed","text":"Hello","audio_duration":123}"#
            default:
                XCTFail("Unexpected request \(request)")
                return .status(404, url: request.url!)
            }
            return .ok(Data(body.utf8), url: request.url!)
        }
        let provider = AssemblyAITranscriptionProvider(session: StubURLProtocol.makeSession())
        let result = try await provider.transcribeFile(
            at: audio, apiKey: "fixture-key", model: AssemblyAIModels.universal35ProBatchID, language: nil
        )
        XCTAssertEqual(result.text, "Hello")
        XCTAssertEqual(result.duration, 0.25, accuracy: 0.0001)
        XCTAssertEqual(result.segments.first?.endTime, 0.25)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 3)
    }
}
