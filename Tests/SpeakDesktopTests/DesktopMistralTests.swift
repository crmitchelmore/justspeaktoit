import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakCore
import SpeakTestSupport
import XCTest
@testable import SpeakDesktop

final class DesktopMistralTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testSharedRouteStreamsNativeWAVAndPreservesFieldsAndSpeakerTiming() async throws {
        let multipart = DesktopMultipartFixture()
        defer { multipart.remove() }
        let audio = try fixture()
        let audioBytes = try Data(contentsOf: audio)
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.mistral.ai/v1/audio/transcriptions")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer desktop-test")
            XCTAssertNil(request.httpBody, "Audio must use a file upload, not an in-memory body")
            let body = try Self.uploadBody(in: multipart.directory)
            for field in ["name=\"model\"", "\r\nvoxtral-mini-latest\r\n", "name=\"language\"", "\r\nen\r\n",
                          "Content-Type: audio/wav", "filename=\"\(audio.lastPathComponent)\""] {
                XCTAssertNotNil(body.range(of: Data(field.utf8)), field)
            }
            XCTAssertNotNil(body.range(of: audioBytes))
            let contentType = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))
            let boundary = try XCTUnwrap(contentType.components(separatedBy: "boundary=").last)
            XCTAssertTrue(body.suffix(Data("\r\n--\(boundary)--\r\n".utf8).count)
                .elementsEqual(Data("\r\n--\(boundary)--\r\n".utf8)))
            return .ok(Data(Self.speakers.utf8), url: request.url!)
        }
        let result = try await transcribe(audio, staging: multipart.staging)
        XCTAssertEqual(result.text, "Speaker 1: Hello.\nSpeaker 2: Shared Mistral.")
        XCTAssertEqual(result.segments.map(\.startTime), [0, 1.5])
        XCTAssertEqual(result.segments.map(\.endTime), [1, 3.5])
        XCTAssertEqual(result.duration, 3.5)
        XCTAssertEqual(result.modelIdentifier, model)
        XCTAssertEqual(result.rawPayload, Self.speakers)
        try assertClean(multipart, retaining: audio)
    }

    func testDurationPrefersProviderThenSegmentThenInjectedRecordingDuration() async throws {
        let multipart = DesktopMultipartFixture()
        defer { multipart.remove() }
        let audio = try fixture()
        let payloads: [(String, TimeInterval)] = [
            (#"{"text":"hello","duration":2,"segments":[{"start":0,"end":3,"text":"hello"}]}"#, 2),
            (#"{"text":"hello","duration":0,"words":[{"start":0,"end":3,"text":"hello"}]}"#, 3),
            (#"{"transcription":"hello"}"#, 7)
        ]
        for (body, expected) in payloads {
            StubURLProtocol.handler = { request in .ok(Data(body.utf8), url: request.url!) }
            let result = try await transcribe(audio, staging: multipart.staging)
            XCTAssertEqual(result.text, "hello")
            XCTAssertEqual(result.duration, expected)
            try assertClean(multipart, retaining: audio)
        }
    }

    func testHTTPDecodingAndTransportFailuresAllRemoveTheStagedBody() async throws {
        let multipart = DesktopMultipartFixture()
        defer { multipart.remove() }
        let audio = try fixture()
        let outcomes: [StubURLProtocol.Outcome] = [
            .status(401, Data("denied".utf8)), .status(429, Data("quota".utf8)),
            .ok(Data("not JSON".utf8)), .fail(URLError(.cannotConnectToHost)),
            .respond(URLResponse(url: URL(string: "https://stub.invalid")!, mimeType: nil,
                                 expectedContentLength: 0, textEncodingName: nil), Data())
        ]
        for outcome in outcomes {
            StubURLProtocol.handler = { _ in outcome }
            do {
                _ = try await transcribe(audio, staging: multipart.staging)
                XCTFail("Expected failure")
            } catch {
                XCTAssertFalse(error is CancellationError)
            }
            try assertClean(multipart, retaining: audio)
        }
    }

    func testCancellingAnActiveUploadRemovesOnlyTheStagedBody() async throws {
        let multipart = DesktopMultipartFixture()
        defer { multipart.remove() }
        let audio = try fixture()
        let accepted = expectation(description: "File upload started")
        StubURLProtocol.handler = { _ in
            XCTAssertFalse(try Self.uploadBody(in: multipart.directory).isEmpty)
            accepted.fulfill()
            return .hang
        }
        let session = StubURLProtocol.makeSession()
        let model = model
        let task = Task {
            try await DesktopTranscription.transcribe(
                audioURL: audio, model: model, apiKey: "desktop-test", duration: 7,
                staging: multipart.staging, session: session
            )
        }
        await fulfillment(of: [accepted], timeout: 5)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        try assertClean(multipart, retaining: audio)
    }

    func testRejectedPrivateDirectoryPreventsNetworkUpload() async throws {
        let audio = try fixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let staging = SharedMultipartUploadStaging(directory: directory, securityPolicy: .init(
            prepareDirectory: { _, _ in throw CocoaError(.fileWriteNoPermission) },
            createFile: { _, _ in XCTFail("Rejected directory"); return false }
        ))
        do {
            _ = try await transcribe(audio, staging: staging)
            XCTFail("Expected private storage failure")
        } catch { XCTAssertEqual((error as? CocoaError)?.code, .fileWriteNoPermission) }
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
    }

    func testMissingSourceRemovesPartialMultipartFileBeforeUpload() async throws {
        let multipart = DesktopMultipartFixture()
        defer { multipart.remove() }
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        do {
            _ = try await transcribe(missing, staging: multipart.staging)
            XCTFail("Expected source read failure")
        } catch { XCTAssertFalse(error is CancellationError) }
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: multipart.directory.path), [])
    }

    func testMultipartCopyPreservesBinaryAudioAcrossChunkBoundaries() throws {
        let multipart = DesktopMultipartFixture()
        defer { multipart.remove() }
        let audio = try fixture(bytes: Data(repeating: 0xFF, count: 2 * 1024 * 1024 + 17), extension: "m4a")
        let url = try MistralBatchClient.makeMultipartUploadBody(
            sourceURL: audio, staging: multipart.staging, boundary: "FixtureBoundary", model: "voxtral-mini-latest",
            language: nil
        )
        defer { multipart.staging.removeUploadBodyFile(at: url) }
        let body = try Data(contentsOf: url)
        let source = try Data(contentsOf: audio)
        XCTAssertNotNil(body.range(of: Data("Content-Type: audio/m4a\r\n\r\n".utf8)))
        XCTAssertNotNil(body.range(of: source))
        XCTAssertLessThan(body.count - source.count, 1_024)
        XCTAssertTrue(body.suffix(23).elementsEqual(Data("\r\n--FixtureBoundary--\r\n".utf8)))
    }

    func testValidationUsesCanonicalProbeAndRedactsTheCredential() async throws {
        let multipart = DesktopMultipartFixture()
        defer { multipart.remove() }
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.absoluteString, "https://api.mistral.ai/v1/models")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-key")
            return .ok(Data(#"{"data":[]}"#.utf8), url: request.url!)
        }
        let result = await MistralBatchClient(
            session: StubURLProtocol.makeSession(), multipartStaging: multipart.staging
        ).validateAPIKey("fixture-key")
        XCTAssertEqual(result.outcome, .success(message: "Mistral API key validated"))
        XCTAssertNotEqual(result.debug?.requestHeaders["Authorization"], "Bearer fixture-key")
        XCTAssertFalse(FileManager.default.fileExists(atPath: multipart.directory.path))
    }

    #if os(Windows)
    func testWindowsRejectsMistralWithoutNativePrivateStorage() async throws {
        do {
            _ = try await DesktopTranscription.transcribe(
                audioURL: fixture(), model: model, apiKey: "fixture-key", duration: 7,
                session: StubURLProtocol.makeSession()
            )
            XCTFail("Windows must require an explicit secure staging policy")
        } catch {
            guard case DesktopTranscriptionError.secureStagingUnavailable = error else {
                return XCTFail("Wrong failure: \(error)")
            }
        }
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
    }
    #endif
}

private extension DesktopMistralTests {
    var model: String { ModelCatalog.batchTranscriptionOptions(forProvider: "mistral")[0].id }

    static let speakers = #"""
    {"segments":[{"start":0,"end":1,"text":"Hello.","speaker":0},
                 {"start":1.5,"end":3.5,"text":"Shared Mistral.","speaker":"speaker_1"}]}
    """#

    func transcribe(_ audio: URL, staging: SharedMultipartUploadStaging) async throws -> TranscriptionResult {
        try await DesktopTranscription.transcribe(
            audioURL: audio, model: model, apiKey: "  desktop-test  ", duration: 7, language: "en_GB",
            staging: staging, session: StubURLProtocol.makeSession()
        )
    }

    func fixture(bytes: Data? = nil, extension suffix: String = "wav") throws -> URL {
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + suffix)
        let content = try bytes ?? XCTUnwrap(PCMWaveWriter.wavData(pcm: Data([0, 255, 255, 127]), sampleRate: 16_000))
        try content.write(to: audio)
        addTeardownBlock { try? FileManager.default.removeItem(at: audio) }
        return audio
    }

    static func uploadBody(in directory: URL) throws -> Data {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        return try Data(contentsOf: XCTUnwrap(files.first))
    }

    func assertClean(_ multipart: DesktopMultipartFixture, retaining audio: URL) throws {
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: multipart.directory.path), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
    }
}
