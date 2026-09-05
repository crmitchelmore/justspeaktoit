import XCTest
@testable import SpeakCore

final class CartesiaBatchClientTests: XCTestCase {
    func testRequestUsesBatchEndpointAndContainerWithLanguageHint() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
        try Data([0, 1, 2, 3]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let request = try CartesiaBatchClient.makeRequest(url: url, apiKey: "fixture", language: "fr-CA")
        XCTAssertEqual(request.url?.absoluteString, "https://api.cartesia.ai/stt")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cartesia-Version"), "2026-08-14")
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("\r\n\r\nink-whisper\r\n"))
        XCTAssertTrue(body.contains("name=\"language\"\r\n\r\nfr\r\n"))
        XCTAssertTrue(body.contains("filename=\"recording.m4a\"\r\nContent-Type: audio/mp4"))
        XCTAssertTrue(body.contains("name=\"timestamp_granularities[]\""))
        let automatic = try CartesiaBatchClient.makeRequest(url: url, apiKey: "fixture", language: nil)
        XCTAssertFalse(String(decoding: automatic.httpBody!, as: UTF8.self).contains("name=\"language\""))
    }

    func testResponsePreservesTranscriptDurationAndWordTimes() throws {
        let data = Data("""
        {"type":"transcript","text":"Hello world","duration":2.5,
         "words":[{"word":"Hello","start":0.2,"end":0.5},{"word":"world","start":0.6,"end":1.1}]}
        """.utf8)
        let result = try CartesiaBatchClient.decode(data)
        XCTAssertEqual(result.text, "Hello world")
        XCTAssertEqual(result.duration, 2.5)
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
