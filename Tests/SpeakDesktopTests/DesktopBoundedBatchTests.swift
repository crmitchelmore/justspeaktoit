import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakCore
import SpeakTestSupport
import XCTest
@testable import SpeakDesktop

final class DesktopBoundedBatchTests: XCTestCase {
    override func tearDown() { StubURLProtocol.reset(); super.tearDown() }

    func testOpenAIGroqAndElevenLabsUseHostStagingAndPreserveFieldsAndSource() async throws {
        let cases = [
            ("openai/whisper-1", "api.openai.com", "Authorization", "Bearer synthetic", "model", "language"),
            ("groq/whisper-large-v3-turbo", "api.groq.com", "Authorization", "Bearer synthetic", "model", "language"),
            ("elevenlabs/scribe_v2", "api.elevenlabs.io", "xi-api-key", "synthetic", "model_id", "language_code")
        ]
        for (model, host, header, credential, modelField, languageField) in cases {
            let fixture = DesktopMultipartFixture()
            defer { fixture.remove() }
            let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
            let audio = Data(repeating: 42, count: 2 * 1024 * 1024 + 17)
            try audio.write(to: source)
            defer { try? FileManager.default.removeItem(at: source) }
            StubURLProtocol.reset()
            StubURLProtocol.handler = { request in
                XCTAssertEqual(request.url?.host, host)
                XCTAssertEqual(request.value(forHTTPHeaderField: header), credential)
                XCTAssertNil(request.httpBody)
                let files = try FileManager.default.contentsOfDirectory(
                    at: fixture.directory, includingPropertiesForKeys: nil
                )
                XCTAssertEqual(files.count, 1)
                let bodyURL = try XCTUnwrap(files.first)
                fixture.staging.purgeStaleUploads(now: .distantFuture)
                let body = try Data(contentsOf: bodyURL)
                XCTAssertNotNil(body.range(of: audio))
                let text = try XCTUnwrap(String(bytes: body, encoding: .utf8))
                XCTAssertTrue(text.contains("name=\"\(modelField)\"\r\n\r\n\(model.split(separator: "/").last!)\r\n"))
                XCTAssertTrue(text.contains("name=\"\(languageField)\"\r\n\r\nen\r\n"))
                XCTAssertTrue(text.contains("Content-Type: audio/wav"))
                return .ok(Data(#"{"text":"bounded result","words":[]}"#.utf8), url: request.url!)
            }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [StubURLProtocol.self]
            let result = try await DesktopTranscription.transcribe(
                audioURL: source, model: model, apiKey: "synthetic", duration: 2, language: "en_GB",
                staging: fixture.staging, session: URLSession(configuration: configuration)
            )
            XCTAssertEqual(result.text, "bounded result")
            XCTAssertEqual(try Data(contentsOf: source), audio)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).isEmpty)
        }
    }
}
