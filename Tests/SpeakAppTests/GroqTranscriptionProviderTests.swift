import Foundation
import XCTest

@testable import SpeakApp
@testable import SpeakCore

final class GroqTranscriptionProviderTests: XCTestCase {
  func testModelCatalogBatchTranscription_includesGroqWhisperTurbo() {
    let ids = ModelCatalog.batchTranscription.map(\.id)

    XCTAssertTrue(ids.contains("groq/whisper-large-v3-turbo"))
  }

  func testProviderRegistry_routesGroqModelToGroqProvider() async {
    let provider = await TranscriptionProviderRegistry.shared.provider(forModel: "groq/whisper-large-v3-turbo")

    XCTAssertEqual(provider?.metadata.id, "groq")
  }

  func testTranscribeFile_usesGroqOpenAICompatibleEndpoint() async throws {
    let requestObserver = GroqRequestObserver()
    GroqMockURLProtocol.requestHandler = { request in
      await requestObserver.store(request: request)
      return try Self.makeResponse(for: request, body: #"{"text":"hello","duration":1.0}"#)
    }
    defer { GroqMockURLProtocol.requestHandler = nil }

    let result = try await makeProvider().transcribeFile(
      at: try makeAudioFile(),
      apiKey: "test-groq-key",
      model: "groq/whisper-large-v3-turbo",
      language: "en_US"
    )

    let capturedRequest = await requestObserver.capturedRequest()
    let capturedBody = await requestObserver.capturedBodyString()
    let request = try XCTUnwrap(capturedRequest)
    let body = try XCTUnwrap(capturedBody)

    XCTAssertEqual(request.url?.absoluteString, "https://api.groq.com/openai/v1/audio/transcriptions")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-groq-key")
    XCTAssertTrue(body.contains("whisper-large-v3-turbo"))
    XCTAssertTrue(body.contains("verbose_json"))
    XCTAssertTrue(body.contains("\r\nen\r\n"))
    XCTAssertEqual(result.text, "hello")
  }

  func testValidateAPIKey_usesGroqModelsEndpoint() async throws {
    let requestObserver = GroqRequestObserver()
    GroqMockURLProtocol.requestHandler = { request in
      await requestObserver.store(request: request)
      return try Self.makeResponse(for: request, body: #"{"data":[]}"#)
    }
    defer { GroqMockURLProtocol.requestHandler = nil }

    let result = await makeProvider().validateAPIKey("test-groq-key")
    let capturedRequest = await requestObserver.capturedRequest()
    let request = try XCTUnwrap(capturedRequest)

    XCTAssertEqual(request.url?.absoluteString, "https://api.groq.com/openai/v1/models")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-groq-key")
    XCTAssertEqual(result.outcome, .success(message: "Groq API key validated"))
  }

  private func makeProvider() -> GroqTranscriptionProvider {
    GroqTranscriptionProvider(session: makeMockSession())
  }

  private func makeMockSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [GroqMockURLProtocol.self]
    return URLSession(configuration: configuration)
  }

  private func makeAudioFile() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("groq-transcription-\(UUID().uuidString).m4a")
    try Data("fake-audio".utf8).write(to: url)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: url)
    }
    return url
  }

  private static func makeResponse(for request: URLRequest, body: String) throws -> (HTTPURLResponse, Data) {
    let response = HTTPURLResponse(
      url: try XCTUnwrap(request.url),
      statusCode: 200,
      httpVersion: nil,
      headerFields: ["Content-Type": "application/json"]
    )!
    return (response, Data(body.utf8))
  }
}

private actor GroqRequestObserver {
  private var request: URLRequest?
  private var body: Data?

  func store(request: URLRequest) {
    self.request = request
    body = request.httpBody ?? readBody(from: request.httpBodyStream)
  }

  func capturedRequest() -> URLRequest? {
    request
  }

  func capturedBodyString() -> String? {
    body.flatMap { String(data: $0, encoding: .utf8) }
  }

  private func readBody(from stream: InputStream?) -> Data? {
    guard let stream else { return nil }
    stream.open()
    defer { stream.close() }

    var data = Data()
    let bufferSize = 4096
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }

    while stream.hasBytesAvailable {
      let readCount = stream.read(buffer, maxLength: bufferSize)
      if readCount <= 0 { break }
      data.append(buffer, count: readCount)
    }
    return data.isEmpty ? nil : data
  }
}

private final class GroqMockURLProtocol: URLProtocol {
  nonisolated(unsafe) static var requestHandler: (@Sendable (URLRequest) async throws -> (HTTPURLResponse, Data))?

  override static func canInit(with request: URLRequest) -> Bool {
    true
  }

  override static func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    guard let handler = Self.requestHandler else {
      XCTFail("GroqMockURLProtocol.requestHandler was not set")
      return
    }

    Task {
      do {
        let (response, data) = try await handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
      } catch {
        client?.urlProtocol(self, didFailWithError: error)
      }
    }
  }

  override func stopLoading() {}
}
