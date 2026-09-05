import Foundation
import XCTest

@testable import SpeakCore

/// Behaviour of the shared Gemini 3.5 Transcribe batch client (issue #862):
/// model and credential guards, the inline transcription path, and the
/// resumable Files API upload with its ACTIVE-state poll. The client moved out
/// of the Mac app so iOS uploads through the same code, so this coverage lives
/// beside it in SpeakCore.
final class GeminiInteractionsClientTests: XCTestCase {
    // MARK: - transcribeFile guards

    func testTranscribeFile_rejectsAModelThisClientDoesNotOwn() async {
        let client = GeminiInteractionsClient(session: self.makeMockSession())

        do {
            _ = try await client.transcribeFile(
                at: URL(fileURLWithPath: "/tmp/does-not-matter.m4a"),
                apiKey: "k",
                model: "google/gemini-2.0-flash-001",
                language: nil
            )
            XCTFail("Expected an unsupportedModel error")
        } catch {
            XCTAssertEqual(error as? GeminiBatchError, .unsupportedModel("google/gemini-2.0-flash-001"))
        }
    }

    func testTranscribeFile_rejectsABlankAPIKeyBeforeTouchingTheDisk() async {
        let client = GeminiInteractionsClient(session: self.makeMockSession())

        do {
            _ = try await client.transcribeFile(
                at: URL(fileURLWithPath: "/tmp/missing.m4a"),
                apiKey: "  ",
                model: GeminiTranscribeModels.batchCatalogID,
                language: nil
            )
            XCTFail("Expected a missingAPIKey error")
        } catch {
            XCTAssertEqual(error as? GeminiBatchError, .missingAPIKey)
        }
    }

    // MARK: - Transcription

    /// Word timings and the diarised `spk_N` labels have to survive the trip:
    /// one segment per annotated word, with the speaker attribution kept in the
    /// raw payload until `TranscriptionSegment` gains a speaker field (#816).
    func testTranscribeFile_inlinesSmallAudioAndKeepsWordTimings() async throws {
        let audioURL = try Self.makeTemporaryAudioFile()
        defer { try? FileManager.default.removeItem(at: audioURL) }

        GeminiMockURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(url.path, "/v1beta/interactions")
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = """
            {"status":"completed","output_text":"Hello world","steps":[{"type":"model_output","content":[
              {"type":"text","text":"Hello world","annotations":[
                {"type":"word_info","text":"Hello","speaker":"spk_1","start_offset":"0.100s","end_offset":"0.450s"},
                {"type":"word_info","text":"world","speaker":"spk_2","start_offset":"0.460s","end_offset":"0.900s"}
              ]}]}]}
            """
            return (response, Data(body.utf8))
        }
        defer { GeminiMockURLProtocol.requestHandler = nil }

        let result = try await GeminiInteractionsClient(session: self.makeMockSession()).transcribeFile(
            at: audioURL, apiKey: "k", model: GeminiTranscribeModels.batchCatalogID, language: nil
        )

        XCTAssertEqual(result.text, "Hello world")
        XCTAssertEqual(result.modelIdentifier, GeminiTranscribeModels.batchCatalogID)
        XCTAssertEqual(result.segments.map(\.text), ["Hello", "world"])
        XCTAssertEqual(result.segments.first?.startTime ?? -1, 0.1, accuracy: 0.0001)
        XCTAssertEqual(result.segments.last?.endTime ?? -1, 0.9, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(result.rawPayload).contains("spk_2"), true)
    }

    func testTranscribeFile_mapsAnAuthFailureOntoTheSharedErrorVocabulary() async throws {
        let audioURL = try Self.makeTemporaryAudioFile()
        defer { try? FileManager.default.removeItem(at: audioURL) }

        GeminiMockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url), statusCode: 401, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(#"{"error":{"code":401,"message":"API key not valid"}}"#.utf8))
        }
        defer { GeminiMockURLProtocol.requestHandler = nil }

        do {
            _ = try await GeminiInteractionsClient(session: self.makeMockSession()).transcribeFile(
                at: audioURL, apiKey: "bad", model: GeminiTranscribeModels.batchCatalogID, language: nil
            )
            XCTFail("Expected an invalidAPIKey error")
        } catch {
            guard case StreamingClientError.invalidAPIKey(let provider) = error else {
                return XCTFail("Expected invalidAPIKey, got \(error)")
            }
            XCTAssertEqual(provider, "Google Gemini")
        }
    }

    // MARK: - Files API

    // A freshly uploaded file is `PROCESSING`; referencing its URI before the
    // Files API reports `ACTIVE` fails the Interactions request. The client
    // polls the file resource and only then transcribes.
    // swiftlint:disable:next function_body_length
    func testUploadedFile_isPolledUntilActiveBeforeTheInteractionsRequest() async throws {
        let recorder = GeminiRequestLog()
        let audioURL = try Self.makeTemporaryAudioFile()
        defer { try? FileManager.default.removeItem(at: audioURL) }

        GeminiMockURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)
            let attempt = await recorder.record(method: request.httpMethod ?? "", path: url.path)

            func respond(_ body: String, headers: [String: String] = [:]) throws -> (HTTPURLResponse, Data) {
                let response = HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: nil, headerFields: headers
                )!
                return (response, Data(body.utf8))
            }

            switch (request.httpMethod, url.path) {
            case ("POST", "/upload/v1beta/files") where request.value(
                forHTTPHeaderField: "X-Goog-Upload-Command") == "start":
                return try respond(
                    "{}",
                    headers: [
                        "x-goog-upload-url": "https://generativelanguage.googleapis.com/upload/session"
                    ]
                )
            case ("POST", "/upload/session"):
                return try respond(
                    #"{"file":{"name":"files/abc123","uri":"\#(Self.fileURI)","state":"PROCESSING"}}"#)
            case ("GET", "/v1beta/files/abc123"):
                let snapshot = await recorder.uploadedFileURL
                XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(snapshot).path))
                // First poll still processing, second one active.
                let state = attempt == 1 ? "PROCESSING" : "ACTIVE"
                return try respond(#"{"name":"files/abc123","uri":"\#(Self.fileURI)","state":"\#(state)"}"#)
            case ("POST", "/v1beta/interactions"):
                return try respond(#"{"status":"completed","output_text":"Hello world"}"#)
            default:
                XCTFail("Unexpected request \(request.httpMethod ?? "") \(url.path)")
                return try respond("{}")
            }
        }
        defer { GeminiMockURLProtocol.requestHandler = nil }

        let session = self.makeMockSession()
        var client = GeminiInteractionsClient(
            session: session,
            // Force the Files API path for a tiny fixture, and keep the poll quick.
            inlineAudioByteLimit: 0,
            filePollInterval: 0.01,
            filePollTimeout: 5
        )
        client.uploadRecording = { request, snapshot in
            await recorder.recordUpload(snapshot)
            return try await session.upload(for: request, fromFile: snapshot)
        }

        let result = try await client.transcribeFile(
            at: audioURL, apiKey: "k", model: GeminiTranscribeModels.batchCatalogID, language: nil
        )

        XCTAssertEqual(result.text, "Hello world")
        let calls = await recorder.calls
        XCTAssertEqual(
            calls,
            [
                "POST /upload/v1beta/files",
                "POST /upload/session",
                "GET /v1beta/files/abc123",
                "GET /v1beta/files/abc123",
                "POST /v1beta/interactions"
            ],
            "the transcription request must wait for the ACTIVE state"
        )
    }

    // swiftlint:disable:next function_body_length
    func testLargeRecordingUsesFileUploadWithItsExactLength() async throws {
        let recorder = GeminiRequestLog()
        let audioURL = try Self.makeTemporaryAudioFile()
        defer { try? FileManager.default.removeItem(at: audioURL) }
        // A sparse file exercises the real large-file route without allocating
        // a recording-sized Data value in either the fixture or the client.
        let byteCount: UInt64 = 32 * 1_024 * 1_024
        let handle = try FileHandle(forWritingTo: audioURL)
        try handle.truncate(atOffset: byteCount)
        try handle.close()

        GeminiMockURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)
            _ = await recorder.record(method: request.httpMethod ?? "", path: url.path)
            var headers: [String: String] = [:]
            let body: String
            switch url.path {
            case "/upload/v1beta/files":
                XCTAssertEqual(
                    request.value(forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length"), String(byteCount)
                )
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Goog-Upload-Protocol"), "resumable")
                headers["x-goog-upload-url"] = "https://generativelanguage.googleapis.com/upload/session"
                try Data([9, 9, 9, 9]).write(to: audioURL, options: .atomic)
                body = "{}"
            case "/upload/session":
                XCTAssertNil(request.httpBody, "The upload must not retain the recording as Data")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Length"), String(byteCount))
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Goog-Upload-Offset"), "0")
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Goog-Upload-Command"), "upload, finalize")
                body = #"{"file":{"name":"files/abc123","uri":"\#(Self.fileURI)","state":"ACTIVE"}}"#
            case "/v1beta/interactions":
                body = #"{"status":"completed","output_text":"Large recording"}"#
            default:
                throw URLError(.unsupportedURL)
            }
            let response = try XCTUnwrap(HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil, headerFields: headers
            ))
            return (response, Data(body.utf8))
        }
        defer { GeminiMockURLProtocol.requestHandler = nil }

        let session = self.makeMockSession()
        var client = GeminiInteractionsClient(session: session)
        client.uploadRecording = { request, snapshot in
            await recorder.recordUpload(snapshot)
            XCTAssertNotEqual(snapshot, audioURL)
            let input = try FileHandle(forReadingFrom: snapshot)
            defer { try? input.close() }
            XCTAssertEqual(try input.read(upToCount: 4), Data([0, 1, 2, 3]))
            var count: UInt64 = 4
            while let chunk = try input.read(upToCount: 65_536), !chunk.isEmpty {
                count += UInt64(chunk.count)
                XCTAssertTrue(chunk.allSatisfy { $0 == 0 })
            }
            XCTAssertEqual(count, byteCount)
            return try await session.upload(for: request, fromFile: snapshot)
        }
        let result = try await client.transcribeFile(
            at: audioURL, apiKey: "k", language: nil
        )
        XCTAssertEqual(result.text, "Large recording")
        let uploadedURL = await recorder.uploadedFileURL
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(uploadedURL).path))
        let calls = await recorder.calls
        XCTAssertEqual(calls, ["POST /upload/v1beta/files", "POST /upload/session", "POST /v1beta/interactions"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path), "Uploading must not delete the source")
    }

    func testUploadedFile_failedProcessingSurfacesAnUploadFailure() async throws {
        let audioURL = try Self.makeTemporaryAudioFile()
        defer { try? FileManager.default.removeItem(at: audioURL) }

        GeminiMockURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: url.path == "/upload/v1beta/files"
                    ? ["x-goog-upload-url": "https://generativelanguage.googleapis.com/upload/session"]
                    : nil
            )!
            switch url.path {
            case "/upload/session":
                return (response, Data(#"{"file":{"name":"files/abc123","uri":"u","state":"FAILED"}}"#.utf8))
            default:
                return (response, Data("{}".utf8))
            }
        }
        defer { GeminiMockURLProtocol.requestHandler = nil }

        let client = GeminiInteractionsClient(
            session: self.makeMockSession(),
            inlineAudioByteLimit: 0,
            filePollInterval: 0.01,
            filePollTimeout: 1
        )

        do {
            _ = try await client.transcribeFile(
                at: audioURL, apiKey: "k", model: GeminiTranscribeModels.batchCatalogID, language: nil
            )
            XCTFail("Expected an uploadFailed error")
        } catch {
            guard case GeminiBatchError.uploadFailed = try XCTUnwrap(error as? GeminiBatchError) else {
                return XCTFail("Expected uploadFailed, got \(error)")
            }
        }
    }

    private static let fileURI = "https://generativelanguage.googleapis.com/v1beta/files/abc123"

    private static func makeTemporaryAudioFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gemini-\(UUID().uuidString).m4a")
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: url, options: .atomic)
        return url
    }

    private func makeMockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GeminiMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

/// Ordered log of the requests a test drove, so a test can assert not just
/// which calls happened but in which order.

private actor GeminiRequestLog {
    private(set) var calls: [String] = []
    private(set) var uploadedFileURL: URL?

    func recordUpload(_ url: URL) {
        self.uploadedFileURL = url
    }

    /// Records one call and answers how many times that same call has been
    /// made, so a handler can vary its answer per attempt.
    func record(method: String, path: String) -> Int {
        let call = "\(method) \(path)"
        self.calls.append(call)
        return self.calls.filter { $0 == call }.count
    }
}

private final class GeminiMockURLProtocol: URLProtocol {
    #if compiler(>=5.10)
        nonisolated(unsafe) static var requestHandler:
            (@Sendable (URLRequest) async throws -> (HTTPURLResponse, Data))?
    #else
        static var requestHandler: (@Sendable (URLRequest) async throws -> (HTTPURLResponse, Data))?
    #endif

    override static func canInit(with request: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            XCTFail("GeminiMockURLProtocol.requestHandler was not set")
            return
        }

        Task {
            do {
                let (response, data) = try await handler(self.request)
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocol(self, didLoad: data)
                self.client?.urlProtocolDidFinishLoading(self)
            } catch {
                self.client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    override func stopLoading() {}
}
