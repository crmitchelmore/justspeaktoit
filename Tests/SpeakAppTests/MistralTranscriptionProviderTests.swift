import Foundation
import XCTest

@testable import SpeakApp
@testable import SpeakCore

final class MistralTranscriptionProviderTests: XCTestCase {
  func testModelCatalogBatchTranscription_includesVoxtralModels() {
    let ids = ModelCatalog.batchTranscription.map(\.id)

    XCTAssertTrue(ids.contains("mistral/voxtral-mini-latest"))
    XCTAssertTrue(ids.contains("mistral/voxtral-small-latest"))
  }

  func testSupportedModels_returnsVoxtralModels() {
    let ids = MistralTranscriptionProvider().supportedModels().map(\.id)

    XCTAssertEqual(ids, [
      "mistral/voxtral-mini-latest",
      "mistral/voxtral-small-latest"
    ])
  }

  func testProviderRegistry_routesVoxtralModelsToMistralProvider() async {
    for model in [
      "mistral/voxtral-mini-latest",
      "mistral/voxtral-small-latest"
    ] {
      let provider = await TranscriptionProviderRegistry.shared.provider(forModel: model)

      XCTAssertEqual(provider?.metadata.id, "mistral", "\(model) should route to Mistral provider")
      XCTAssertEqual(provider?.metadata.apiKeyIdentifier, "mistral.apiKey")
    }
  }

  func testAllProviders_includesMistralMetadataForAPIKeySettings() async {
    let providers = await TranscriptionProviderRegistry.shared.allProviders()

    let mistral = providers.first { $0.id == "mistral" }
    XCTAssertEqual(mistral?.displayName, "Mistral")
    XCTAssertEqual(mistral?.apiKeyLabel, "Mistral API Key")
  }

  func testTranscribeFile_usesMistralMultipartEndpoint() async throws {
    let requestObserver = MistralRequestObserver()
    MistralMockURLProtocol.requestHandler = { request in
      await requestObserver.store(request: request)
      return try Self.makeResponse(for: request, body: #"{"text":"hello world","duration":1.25}"#)
    }
    defer { MistralMockURLProtocol.requestHandler = nil }

    let result = try await makeProvider().transcribeFile(
      at: try makeAudioFile(),
      apiKey: "test-mistral-key",
      model: "mistral/voxtral-mini-latest",
      language: "en_GB"
    )

    let capturedRequest = await requestObserver.capturedRequest()
    let capturedBody = await requestObserver.capturedBodyString()
    let request = try XCTUnwrap(capturedRequest)
    let body = try XCTUnwrap(capturedBody)

    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.url?.absoluteString, "https://api.mistral.ai/v1/audio/transcriptions")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-mistral-key")
    let contentType = request.value(forHTTPHeaderField: "Content-Type")
    XCTAssertTrue(contentType?.hasPrefix("multipart/form-data; boundary=") == true)
    XCTAssertTrue(body.contains(#"name="model""#))
    XCTAssertTrue(body.contains("\r\nvoxtral-mini-latest\r\n"))
    XCTAssertFalse(body.contains("\r\nmistral/voxtral-mini-latest\r\n"))
    XCTAssertTrue(body.contains(#"name="file"; filename=""#))
    XCTAssertFalse(body.contains("response_format"))
    XCTAssertEqual(result.text, "hello world")
    XCTAssertEqual(result.duration, 1.25)
    XCTAssertEqual(result.modelIdentifier, "mistral/voxtral-mini-latest")
  }

  func testTranscribeFile_mapsSegments() async throws {
    let responseBody = """
    {
      "text": "Hello there. Hi back.",
      "duration": 2.0,
      "segments": [
        {"start": 0.0, "end": 1.0, "text": "Hello there."},
        {"start": 1.1, "end": 2.0, "text": "Hi back."}
      ]
    }
    """
    MistralMockURLProtocol.requestHandler = { request in
      try Self.makeResponse(for: request, body: responseBody)
    }
    defer { MistralMockURLProtocol.requestHandler = nil }

    let result = try await makeProvider().transcribeFile(
      at: try makeAudioFile(),
      apiKey: "test-mistral-key",
      model: "mistral/voxtral-small-latest",
      language: nil
    )

    XCTAssertEqual(result.text, "Hello there. Hi back.")
    XCTAssertEqual(result.duration, 2.0)
    XCTAssertEqual(result.segments.map(\.text), ["Hello there.", "Hi back."])
    XCTAssertEqual(result.segments.map(\.startTime), [0.0, 1.1])
    XCTAssertEqual(result.segments.map(\.endTime), [1.0, 2.0])
  }

  func testTranscribeFile_labelsSpeakerSegmentsWhenPresent() async throws {
    let responseBody = """
    {
      "duration": 2.0,
      "segments": [
        {"start": 0.0, "end": 1.0, "text": "Hello there.", "speaker": 0},
        {"start": 1.1, "end": 2.0, "text": "Hi back.", "speaker": 1}
      ]
    }
    """
    MistralMockURLProtocol.requestHandler = { request in
      try Self.makeResponse(for: request, body: responseBody)
    }
    defer { MistralMockURLProtocol.requestHandler = nil }

    let result = try await makeProvider().transcribeFile(
      at: try makeAudioFile(),
      apiKey: "test-mistral-key",
      model: "mistral/voxtral-small-latest",
      language: nil
    )

    XCTAssertEqual(result.text, "Speaker 1: Hello there.\nSpeaker 2: Hi back.")
    XCTAssertEqual(result.segments.map(\.text), ["Speaker 1: Hello there.", "Speaker 2: Hi back."])
  }

  func testValidateAPIKey_usesMistralModelsEndpoint() async throws {
    let requestObserver = MistralRequestObserver()
    MistralMockURLProtocol.requestHandler = { request in
      await requestObserver.store(request: request)
      return try Self.makeResponse(for: request, body: #"{"data":[]}"#)
    }
    defer { MistralMockURLProtocol.requestHandler = nil }

    let result = await makeProvider().validateAPIKey("test-mistral-key")
    let capturedRequest = await requestObserver.capturedRequest()
    let request = try XCTUnwrap(capturedRequest)

    XCTAssertEqual(request.url?.absoluteString, "https://api.mistral.ai/v1/models")
    XCTAssertEqual(request.httpMethod, "GET")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-mistral-key")
    XCTAssertEqual(result.outcome, .success(message: "Mistral API key validated"))
    XCTAssertNotEqual(result.debug?.requestHeaders["Authorization"], "Bearer test-mistral-key")
  }

  func testValidateAPIKey_returnsFailureForEmptyKey() async {
    let result = await MistralTranscriptionProvider().validateAPIKey("  ")

    XCTAssertEqual(result.outcome, .failure(message: "API key is empty"))
  }

  private func makeProvider() -> MistralTranscriptionProvider {
    MistralTranscriptionProvider(session: makeMockSession())
  }

  private func makeMockSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MistralMockURLProtocol.self]
    return URLSession(configuration: configuration)
  }

  private func makeAudioFile() throws -> URL {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let directory = root.appendingPathComponent(".build/test-audio", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("mistral-transcription-\(UUID().uuidString).m4a")
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

private actor MistralRequestObserver {
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

private final class MistralMockURLProtocol: URLProtocol {
  nonisolated(unsafe) static var requestHandler: (@Sendable (URLRequest) async throws -> (HTTPURLResponse, Data))?

  override static func canInit(with request: URLRequest) -> Bool {
    true
  }

  override static func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    guard let handler = Self.requestHandler else {
      XCTFail("MistralMockURLProtocol.requestHandler was not set")
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
