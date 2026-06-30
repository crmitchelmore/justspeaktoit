import Foundation
import XCTest

@testable import SpeakApp
@testable import SpeakCore

final class SonioxAsyncTranscriptionProviderTests: XCTestCase {
  func testModelCatalogBatchTranscription_includesSonioxAsyncV5() {
    let ids = ModelCatalog.batchTranscription.map(\.id)

    XCTAssertTrue(ids.contains("soniox/stt-async-v5"))
  }

  func testProviderRegistry_routesSonioxAsyncToSonioxProvider() async {
    let provider = await TranscriptionProviderRegistry.shared.provider(forModel: "soniox/stt-async-v5")

    XCTAssertEqual(provider?.metadata.id, "soniox")
  }

  func testProviderRegistry_stillRoutesSonioxLiveToSonioxProvider() async {
    let provider = await TranscriptionProviderRegistry.shared.provider(forModel: "soniox/stt-rt-v5-streaming")

    XCTAssertEqual(provider?.metadata.id, "soniox")
  }

  func testTranscribeFile_uploadsCreatesPollsAndFetchesTranscript() async throws {
    let requestObserver = SonioxRequestObserver()
    SonioxMockURLProtocol.requestHandler = { request in
      await requestObserver.store(request: request)
      return try Self.makeResponse(for: request)
    }
    defer { SonioxMockURLProtocol.requestHandler = nil }

    let provider = SonioxTranscriptionProvider(
      session: makeMockSession(),
      pollingDelay: .milliseconds(1),
      maximumPollingAttempts: 2
    )
    let result = try await provider.transcribeFile(
      at: try makeAudioFile(),
      apiKey: "test-soniox-key",
      model: "soniox/stt-async-v5",
      language: "en_GB"
    )

    let requests = await requestObserver.capturedRequests()
    XCTAssertEqual(requests.map(\.url?.path), [
      "/v1/files",
      "/v1/transcriptions",
      "/v1/transcriptions/transcription-1",
      "/v1/transcriptions/transcription-1/transcript"
    ])
    let capturedBody = await requestObserver.bodyString(forPath: "/v1/transcriptions")
    let createBody = try XCTUnwrap(capturedBody)
    XCTAssertTrue(createBody.contains(#""model":"stt-async-v5""#))
    XCTAssertTrue(createBody.contains(#""file_id":"file-1""#))
    XCTAssertTrue(createBody.contains(#""language_hints":["en"]"#))
    XCTAssertTrue(createBody.contains(#""enable_speaker_diarization":true"#))
    XCTAssertTrue(createBody.contains(#""enable_language_identification":true"#))
    XCTAssertEqual(result.text, "Speaker 1: Hello \nSpeaker 2: there")
    XCTAssertEqual(result.duration, 1.0)
    XCTAssertEqual(result.segments.map(\.text), ["Speaker 1: Hello ", "Speaker 2: there"])
  }

  func testTranscribeFile_throwsWhenPollingReportsError() async throws {
    SonioxMockURLProtocol.requestHandler = { request in
      switch request.url?.path {
      case "/v1/files":
        return try Self.makeResponse(for: request, body: #"{"id":"file-1"}"#, statusCode: 201)
      case "/v1/transcriptions":
        return try Self.makeResponse(
          for: request,
          body: #"{"id":"transcription-1","status":"queued"}"#,
          statusCode: 201
        )
      case "/v1/transcriptions/transcription-1":
        return try Self.makeResponse(
          for: request,
          body: #"{"id":"transcription-1","status":"error","error_message":"bad audio"}"#
        )
      default:
        XCTFail("Unexpected request \(request.url?.absoluteString ?? "")")
        return try Self.makeResponse(for: request)
      }
    }
    defer { SonioxMockURLProtocol.requestHandler = nil }

    let provider = SonioxTranscriptionProvider(
      session: makeMockSession(),
      pollingDelay: .milliseconds(1),
      maximumPollingAttempts: 2
    )

    do {
      _ = try await provider.transcribeFile(
        at: try makeAudioFile(),
        apiKey: "test-soniox-key",
        model: "soniox/stt-async-v5",
        language: nil
      )
      XCTFail("Expected failed Soniox job to throw")
    } catch SonioxLiveError.transcriptionFailed(let message) {
      XCTAssertEqual(message, "bad audio")
    }
  }

  private func makeMockSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SonioxMockURLProtocol.self]
    return URLSession(configuration: configuration)
  }

  private func makeAudioFile() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("soniox-async-\(UUID().uuidString).m4a")
    try Data("fake-audio".utf8).write(to: url)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: url)
    }
    return url
  }

  private static func makeResponse(
    for request: URLRequest,
    body: String? = nil,
    statusCode: Int = 200
  ) throws -> (HTTPURLResponse, Data) {
    let response = HTTPURLResponse(
      url: try XCTUnwrap(request.url),
      statusCode: statusCode,
      httpVersion: nil,
      headerFields: ["Content-Type": "application/json"]
    )!
    let payload = body ?? payload(forPath: request.url?.path)
    return (response, Data(payload.utf8))
  }

  private static func payload(forPath path: String?) -> String {
    switch path {
    case "/v1/files":
      return #"{"id":"file-1"}"#
    case "/v1/transcriptions":
      return #"{"id":"transcription-1","status":"queued"}"#
    case "/v1/transcriptions/transcription-1":
      return #"{"id":"transcription-1","status":"completed","audio_duration_ms":1000}"#
    case "/v1/transcriptions/transcription-1/transcript":
      return """
      {
        "id": "transcription-1",
        "text": "Hello there",
        "tokens": [
          {"text": "Hello ", "start_ms": 0, "end_ms": 500, "confidence": 0.9, "speaker": "1"},
          {"text": "there", "start_ms": 500, "end_ms": 1000, "confidence": 0.8, "speaker": "2"}
        ]
      }
      """
    default:
      return #"{"id":"unexpected"}"#
    }
  }
}

private actor SonioxRequestObserver {
  private var requests: [URLRequest] = []
  private var bodiesByPath: [String: Data] = [:]

  func store(request: URLRequest) {
    requests.append(request)
    if let path = request.url?.path {
      bodiesByPath[path] = request.httpBody ?? readBody(from: request.httpBodyStream)
    }
  }

  func capturedRequests() -> [URLRequest] {
    requests
  }

  func bodyString(forPath path: String) -> String? {
    bodiesByPath[path].flatMap { String(data: $0, encoding: .utf8) }
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

private final class SonioxMockURLProtocol: URLProtocol {
#if compiler(>=5.10)
  nonisolated(unsafe) static var requestHandler: (@Sendable (URLRequest) async throws -> (HTTPURLResponse, Data))?
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
      XCTFail("SonioxMockURLProtocol.requestHandler was not set")
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
