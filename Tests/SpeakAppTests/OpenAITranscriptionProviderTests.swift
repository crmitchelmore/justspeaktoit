import Foundation
import XCTest

@testable import SpeakApp
@testable import SpeakCore

final class OpenAITranscriptionProviderTests: XCTestCase {
  func testModelCatalogBatchTranscription_includesGPT4oTranscribeDiarize() {
    let ids = ModelCatalog.batchTranscription.map(\.id)

    XCTAssertTrue(ids.contains("openai/gpt-4o-transcribe-diarize"))
  }

  func testSupportedModels_includeGPT4oTranscriptionFamily() {
    let ids = OpenAITranscriptionProvider().supportedModels().map(\.id)

    XCTAssertTrue(ids.contains("openai/whisper-1"))
    XCTAssertTrue(ids.contains("openai/gpt-4o-mini-transcribe"))
    XCTAssertTrue(ids.contains("openai/gpt-4o-transcribe"))
    XCTAssertTrue(ids.contains("openai/gpt-4o-transcribe-diarize"))
  }

  func testProviderRegistry_routesGPT4oTranscriptionFamilyToOpenAIProvider() async {
    for model in [
      "openai/gpt-4o-mini-transcribe",
      "openai/gpt-4o-transcribe",
      "openai/gpt-4o-transcribe-diarize"
    ] {
      let provider = await TranscriptionProviderRegistry.shared.provider(forModel: model)
      XCTAssertEqual(provider?.metadata.id, "openai", "\(model) should route to OpenAI provider")
    }
  }

  func testTranscribeFileWithGPT4oTranscribe_usesJSONResponseFormat() async throws {
    let requestObserver = OpenAIRequestObserver()
    OpenAIMockURLProtocol.requestHandler = { request in
      await requestObserver.store(request: request)
      return try Self.makeResponse(for: request, body: #"{"text":"hello world","duration":1.25}"#)
    }
    defer { OpenAIMockURLProtocol.requestHandler = nil }

    let result = try await makeProvider().transcribeFile(
      at: try makeAudioFile(),
      apiKey: "test-openai-key",
      model: "openai/gpt-4o-transcribe",
      language: "en_GB"
    )

    let capturedBody = await requestObserver.capturedBodyString()
    let body = try XCTUnwrap(capturedBody)
    XCTAssertTrue(body.contains(#"name="model""#))
    XCTAssertTrue(body.contains("gpt-4o-transcribe"))
    XCTAssertTrue(body.contains(#"name="response_format""#))
    XCTAssertTrue(body.contains("json"))
    XCTAssertFalse(body.contains("verbose_json"))
    XCTAssertFalse(body.contains("chunking_strategy"))
    XCTAssertTrue(body.contains(#"name="language""#))
    XCTAssertTrue(body.contains("\r\nen\r\n"))
    XCTAssertEqual(result.text, "hello world")
    XCTAssertEqual(result.duration, 1.25)
  }

  func testTranscribeFileWithDiarize_usesDiarizedJSONAndLabelsSpeakers() async throws {
    let requestObserver = OpenAIRequestObserver()
    let responseBody = """
    {
      "text": "Hello there. Hi back.",
      "segments": [
        {"speaker": "SPEAKER_00", "start": 0.0, "end": 1.0, "text": "Hello there."},
        {"speaker": "SPEAKER_01", "start": 1.1, "end": 2.0, "text": "Hi back."}
      ]
    }
    """
    OpenAIMockURLProtocol.requestHandler = { request in
      await requestObserver.store(request: request)
      return try Self.makeResponse(for: request, body: responseBody)
    }
    defer { OpenAIMockURLProtocol.requestHandler = nil }

    let result = try await makeProvider().transcribeFile(
      at: try makeAudioFile(),
      apiKey: "test-openai-key",
      model: "openai/gpt-4o-transcribe-diarize",
      language: nil
    )

    let capturedBody = await requestObserver.capturedBodyString()
    let body = try XCTUnwrap(capturedBody)
    XCTAssertTrue(body.contains("gpt-4o-transcribe-diarize"))
    XCTAssertTrue(body.contains("diarized_json"))
    XCTAssertTrue(body.contains(#"name="chunking_strategy""#))
    XCTAssertTrue(body.contains("\r\nauto\r\n"))
    XCTAssertEqual(result.text, "Speaker 1: Hello there.\nSpeaker 2: Hi back.")
    XCTAssertEqual(result.duration, 2.0)
    XCTAssertEqual(result.segments.map(\.text), ["Speaker 1: Hello there.", "Speaker 2: Hi back."])
  }

  private func makeProvider() -> OpenAITranscriptionProvider {
    OpenAITranscriptionProvider(session: makeMockSession())
  }

  private func makeMockSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [OpenAIMockURLProtocol.self]
    return URLSession(configuration: configuration)
  }

  private func makeAudioFile() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("openai-transcription-\(UUID().uuidString).m4a")
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

private actor OpenAIRequestObserver {
  private var request: URLRequest?
  private var body: Data?

  func store(request: URLRequest) {
    self.request = request
    body = request.httpBody ?? readBody(from: request.httpBodyStream)
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

private final class OpenAIMockURLProtocol: URLProtocol {
  nonisolated(unsafe) static var requestHandler: (@Sendable (URLRequest) async throws -> (HTTPURLResponse, Data))?

  override static func canInit(with request: URLRequest) -> Bool {
    true
  }

  override static func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    guard let handler = Self.requestHandler else {
      XCTFail("OpenAIMockURLProtocol.requestHandler was not set")
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
