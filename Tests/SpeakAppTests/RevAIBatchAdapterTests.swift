import Foundation
import SpeakCore
import SpeakTestSupport
import XCTest
@testable import SpeakApp

final class RevAIBatchAdapterTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testAppleAdapterKeepsNativeDurationAndSharedStreamedUpload() async throws {
        let fixture = try fixtures()
        let audio = fixture.audio
        let staging = fixture.staging
        let directory = fixture.directory
        StubURLProtocol.handler = { request in
            let body: String
            switch request.url?.path {
            case "/speechtotext/v1/jobs":
                XCTAssertNil(request.httpBody)
                body = #"{"id":"job-1","status":"in_progress"}"#
            case "/speechtotext/v1/jobs/job-1":
                body = #"{"id":"job-1","status":"transcribed"}"#
            default:
                XCTAssertEqual(request.url?.path, "/speechtotext/v1/jobs/job-1/transcript")
                body = #"{"monologues":[{"elements":[{"type":"text","value":"Hello","ts":0,"end_ts":2}]}]}"#
            }
            return .ok(Data(body.utf8), url: request.url!)
        }
        let provider = RevAITranscriptionProvider(session: StubURLProtocol.makeSession(), multipartStaging: staging)
        let result = try await provider.transcribeFile(
            at: audio, apiKey: "fixture-key", model: "revai/default", language: nil
        )
        XCTAssertEqual(result.duration, 1, accuracy: 0.001)
        XCTAssertEqual(result.segments.first?.endTime, 2)
        XCTAssertEqual(result.text, "Hello")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
    }

    func testAppleAdapterPropagatesUploadFailureAndRemovesOnlyStaging() async throws {
        let fixture = try fixtures()
        let audio = fixture.audio
        let staging = fixture.staging
        let directory = fixture.directory
        StubURLProtocol.handler = { request in .status(401, Data("denied".utf8), url: request.url!) }
        let provider = RevAITranscriptionProvider(session: StubURLProtocol.makeSession(), multipartStaging: staging)
        do {
            _ = try await provider.transcribeFile(
                at: audio, apiKey: "fixture-key", model: "revai/default", language: nil
            )
            XCTFail("Expected provider failure")
        } catch { XCTAssertEqual(error as? TranscriptionProviderError, .httpError(401, "denied")) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
        XCTAssertEqual(provider.supportedModels(), ModelCatalog.batchTranscriptionOptions(forProvider: "revai"))
        XCTAssertEqual(provider.metadata.apiKeyIdentifier, "revai.apiKey")
    }

    private func fixtures() throws -> RevAIFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("fixture.wav")
        try XCTUnwrap(PCMWaveWriter.wavData(
            pcm: Data(repeating: 0, count: 32_000), sampleRate: 16_000
        )).write(to: audio)
        let directory = root.appendingPathComponent("uploads")
        return RevAIFixture(audio: audio, staging: MultipartUploadStaging(directory: directory), directory: directory)
    }
}

private struct RevAIFixture {
    let audio: URL
    let staging: MultipartUploadStaging
    let directory: URL
}
