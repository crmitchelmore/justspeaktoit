import XCTest
@testable import SpeakCore

final class CartesiaBatchClientTests: XCTestCase {
    func testRequestUsesBatchEndpointAndContainerWithLanguageHint() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
        try Data([0, 1, 2, 3]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let upload = try CartesiaBatchClient.makeUpload(url: url, apiKey: "fixture", language: "fr-CA")
        defer { try? FileManager.default.removeItem(at: upload.file.deletingLastPathComponent()) }
        let request = upload.request
        XCTAssertNil(request.httpBody)
        XCTAssertEqual(request.url?.absoluteString, "https://api.cartesia.ai/stt")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cartesia-Version"), "2026-08-14")
        let body = try XCTUnwrap(String(bytes: Data(contentsOf: upload.file), encoding: .utf8))
        XCTAssertTrue(body.contains("\r\n\r\nink-whisper\r\n"))
        XCTAssertTrue(body.contains("name=\"language\"\r\n\r\nfr\r\n"))
        XCTAssertTrue(body.contains("filename=\"recording.m4a\"\r\nContent-Type: audio/mp4"))
        XCTAssertTrue(body.contains("name=\"timestamp_granularities[]\""))
        for language in [nil, " automatic ", "AUTOMATIC", " "] as [String?] {
            let automatic = try CartesiaBatchClient.makeUpload(url: url, apiKey: "fixture", language: language)
            defer { try? FileManager.default.removeItem(at: automatic.file.deletingLastPathComponent()) }
            let automaticBody = try XCTUnwrap(String(bytes: Data(contentsOf: automatic.file), encoding: .utf8))
            XCTAssertFalse(automaticBody.contains("name=\"language\""))
        }
    }

    func testCancelledTransferRemovesSnapshotAndPreservesSource() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        try Data([0, 1, 2, 3]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = UploadPathRecorder()
        var client = CartesiaBatchClient()
        client.uploadRecording = { request, file in
            await recorder.record(file)
            XCTAssertNil(request.httpBody)
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
            throw URLError(.cancelled)
        }
        do {
            _ = try await client.transcribeFile(at: url, apiKey: "fixture", language: nil)
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            let file = await recorder.file
            XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(file).path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testLargeMultipartSnapshotPreservesOriginalBytesWithoutAnHTTPBody() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        try Data([1, 2, 3, 4]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try FileHandle(forWritingTo: url)
        try source.truncate(atOffset: 32 * 1_024 * 1_024)
        try source.close()
        let upload = try CartesiaBatchClient.makeUpload(url: url, apiKey: "fixture", language: nil)
        defer { try? FileManager.default.removeItem(at: upload.file.deletingLastPathComponent()) }
        XCTAssertNil(upload.request.httpBody)
        try Data([9]).write(to: url, options: .atomic)
        let input = try FileHandle(forReadingFrom: upload.file)
        defer { try? input.close() }
        let prefix = try XCTUnwrap(input.read(upToCount: 1_024))
        XCTAssertNotNil(prefix.range(of: Data([1, 2, 3, 4])))
        var bytes = prefix.count
        while let chunk = try input.read(upToCount: 65_536), !chunk.isEmpty { bytes += chunk.count }
        XCTAssertGreaterThan(bytes, 32 * 1_024 * 1_024)
        XCTAssertLessThan(bytes, 32 * 1_024 * 1_024 + 1_024)
    }

    func testResponsePreservesTranscriptDurationAndWordTimes() throws {
        let data = Data("""
        {"type":"transcript","text":"Hello world","duration":2.5,
         "words":[{"word":"Hello","start":0.2,"end":0.5},{"word":"world","start":0.6,"end":1.1}]}
        """.utf8)
        let result = try CartesiaBatchClient.decode(data)
        XCTAssertEqual(result.text, "Hello world")
        XCTAssertEqual(result.duration, 2.5)
        let withoutDuration = try XCTUnwrap(String(bytes: data, encoding: .utf8))
            .replacingOccurrences(of: "\"duration\":2.5,", with: "")
        XCTAssertEqual(try CartesiaBatchClient.decode(Data(withoutDuration.utf8)).duration, 1.1)
        XCTAssertEqual(result.segments.count, 2)
        XCTAssertEqual(result.segments.first?.startTime, 0.2)
        XCTAssertEqual(result.modelIdentifier, CartesiaBatchClient.catalogID)
        XCTAssertThrowsError(try CartesiaBatchClient.decode(Data(#"{"error":"bad key"}"#.utf8)))
        let silent = try CartesiaBatchClient.decode(Data(#"{"type":"transcript","text":"","duration":1}"#.utf8))
        XCTAssertEqual(silent.text, "")
    }

    func testCatalogueAndCredentialStayOnCartesiaBatchRoute() {
        XCTAssertTrue(ModelCatalog.batchTranscription.contains { $0.id == CartesiaBatchClient.catalogID })
        XCTAssertFalse(ModelCatalog.liveTranscription.contains { $0.id == CartesiaBatchClient.catalogID })
        XCTAssertEqual(ModelCredentialResolver.requirement(for: CartesiaBatchClient.catalogID,
                                                         purpose: .batchTranscription),
                       .apiKey(identifier: "cartesia.apiKey", providerName: "Cartesia"))
    }
}

private actor UploadPathRecorder {
    var file: URL?
    func record(_ file: URL) { self.file = file }
}
