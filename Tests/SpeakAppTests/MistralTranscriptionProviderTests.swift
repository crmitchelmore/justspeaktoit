import Foundation
import SpeakTestSupport
import XCTest

@testable import SpeakApp
@testable import SpeakCore

final class MistralTranscriptionProviderTests: XCTestCase {
  func testModelCatalogBatchTranscription_includesVoxtralModels() {
    let ids = ModelCatalog.batchTranscription.map(\.id)

    XCTAssertTrue(ids.contains("mistral/voxtral-mini-latest"))
  }

  func testSupportedModels_returnsVoxtralModels() {
    let ids = MistralTranscriptionProvider().supportedModels().map(\.id)

    XCTAssertEqual(ids, [
      "mistral/voxtral-mini-latest"
    ])
  }

  func testProviderRegistry_routesVoxtralModelsToMistralProvider() async {
    for model in [
      "mistral/voxtral-mini-latest"
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
    StubURLProtocol.respond {  request in
      await requestObserver.store(request: request)
      return try Self.makeResponse(for: request, body: #"{"text":"hello world","duration":1.25}"#)
    }
    defer { StubURLProtocol.reset() }

    let result = try await makeProvider().transcribeFile(
      at: try makeAudioFile(),
      apiKey: "test-mistral-key",
      model: "mistral/voxtral-mini-latest",
      language: "en_GB"
    )

    let capturedRequest = await requestObserver.capturedRequest()
    let request = try XCTUnwrap(capturedRequest)

    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.url?.absoluteString, "https://api.mistral.ai/v1/audio/transcriptions")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-mistral-key")
    let contentType = request.value(forHTTPHeaderField: "Content-Type")
    XCTAssertTrue(contentType?.hasPrefix("multipart/form-data; boundary=") == true)
    XCTAssertEqual(result.text, "hello world")
    XCTAssertEqual(result.duration, 1.25)
    XCTAssertEqual(result.modelIdentifier, "mistral/voxtral-mini-latest")
  }

  func testMultipartUploadBody_preservesFieldsAndStreamsAudioBytesToDisk() throws {
    let audioURL = try makeAudioFile(contents: Data([0x00, 0x01, 0xFE, 0xFF]))
    let directory = try makeTemporaryDirectory()
    let bodyURL = try MistralTranscriptionProvider.makeMultipartUploadBody(
      sourceURL: audioURL,
      staging: MultipartUploadStaging(directory: directory),
      boundary: "TestBoundary",
      model: "voxtral-mini-latest",
      language: "en"
    )
    defer { try? FileManager.default.removeItem(at: bodyURL) }

    let body = try Data(contentsOf: bodyURL)
    let bodyText = try XCTUnwrap(String(data: body, encoding: .isoLatin1))

    XCTAssertTrue(bodyText.contains(#"name="model""#))
    XCTAssertTrue(bodyText.contains("\r\nvoxtral-mini-latest\r\n"))
    XCTAssertTrue(bodyText.contains(#"name="language""#))
    XCTAssertTrue(bodyText.contains("\r\nen\r\n"))
    XCTAssertTrue(bodyText.contains(#"name="file"; filename=""#))
    XCTAssertTrue(bodyText.contains("Content-Type: audio/m4a"))
    XCTAssertTrue(bodyText.contains("\u{0}\u{1}þÿ"))
    XCTAssertTrue(bodyText.hasSuffix("\r\n--TestBoundary--\r\n"))
  }

  func testMultipartUploadBody_escapesFilenameAndRemovesHeaderBreaks() throws {
    let audioURL = try makeAudioFile(filename: "audio\"\\\r\nX-Evil: true.m4a")
    let directory = try makeTemporaryDirectory()
    let bodyURL = try MistralTranscriptionProvider.makeMultipartUploadBody(
      sourceURL: audioURL,
      staging: MultipartUploadStaging(directory: directory),
      boundary: "TestBoundary",
      model: "voxtral-mini-latest",
      language: nil
    )
    defer { try? FileManager.default.removeItem(at: bodyURL) }

    let body = try Data(contentsOf: bodyURL)
    let bodyText = try XCTUnwrap(String(data: body, encoding: .utf8))

    XCTAssertTrue(bodyText.contains(#"filename="audio\"\\X-Evil: true.m4a""#))
    XCTAssertFalse(bodyText.contains("\r\nX-Evil: true.m4a"))
  }

  func testTranscribeFile_removesMultipartFileAfterSuccessfulUpload() async throws {
    let directory = try makeTemporaryDirectory()
    StubURLProtocol.respond {  request in
      try Self.makeResponse(for: request, body: #"{"text":"hello","duration":1}"#)
    }
    defer { StubURLProtocol.reset() }

    _ = try await makeProvider(multipartDirectory: directory).transcribeFile(
      at: try makeAudioFile(),
      apiKey: "test-mistral-key",
      model: "mistral/voxtral-mini-latest",
      language: nil
    )

    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
  }

  func testTranscribeFile_removesMultipartFileAfterFailedUpload() async throws {
    let directory = try makeTemporaryDirectory()
    StubURLProtocol.respond {  _ in
      throw URLError(.cannotConnectToHost)
    }
    defer { StubURLProtocol.reset() }

    do {
      _ = try await makeProvider(multipartDirectory: directory).transcribeFile(
        at: try makeAudioFile(),
        apiKey: "test-mistral-key",
        model: "mistral/voxtral-mini-latest",
        language: nil
      )
      XCTFail("Expected the upload to fail")
    } catch {
      XCTAssertEqual((error as? URLError)?.code, .cannotConnectToHost)
    }

    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
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
    StubURLProtocol.respond {  request in
      try Self.makeResponse(for: request, body: responseBody)
    }
    defer { StubURLProtocol.reset() }

    let result = try await makeProvider().transcribeFile(
      at: try makeAudioFile(),
      apiKey: "test-mistral-key",
      model: "mistral/voxtral-mini-latest",
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
    StubURLProtocol.respond {  request in
      try Self.makeResponse(for: request, body: responseBody)
    }
    defer { StubURLProtocol.reset() }

    let result = try await makeProvider().transcribeFile(
      at: try makeAudioFile(),
      apiKey: "test-mistral-key",
      model: "mistral/voxtral-mini-latest",
      language: nil
    )

    XCTAssertEqual(result.text, "Speaker 1: Hello there.\nSpeaker 2: Hi back.")
    XCTAssertEqual(result.segments.map(\.text), ["Speaker 1: Hello there.", "Speaker 2: Hi back."])
  }

  func testTranscribeFile_preservesOneIndexedSpeakerLabels() async throws {
    let responseBody = """
    {
      "duration": 1.0,
      "segments": [
        {"start": 0.0, "end": 1.0, "text": "Hello there.", "speaker": "Speaker 1"}
      ]
    }
    """
    StubURLProtocol.respond {  request in
      try Self.makeResponse(for: request, body: responseBody)
    }
    defer { StubURLProtocol.reset() }

    let result = try await makeProvider().transcribeFile(
      at: try makeAudioFile(),
      apiKey: "test-mistral-key",
      model: "mistral/voxtral-mini-latest",
      language: nil
    )

    XCTAssertEqual(result.text, "Speaker 1: Hello there.")
  }

  func testValidateAPIKey_usesMistralModelsEndpoint() async throws {
    let requestObserver = MistralRequestObserver()
    StubURLProtocol.respond {  request in
      await requestObserver.store(request: request)
      return try Self.makeResponse(for: request, body: #"{"data":[]}"#)
    }
    defer { StubURLProtocol.reset() }

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

  private func makeAudioFile(
    contents: Data = Data("fake-audio".utf8),
    filename: String = "mistral-transcription-\(UUID().uuidString).m4a"
  ) throws -> URL {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let directory = root.appendingPathComponent(".build/test-audio", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent(filename)
    try contents.write(to: url)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: url)
    }
    return url
  }

  private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("mistral-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: directory)
    }
    return directory
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

private func makeProvider(
  multipartDirectory: URL = FileManager.default.temporaryDirectory
    .appendingPathComponent("speak-multipart-uploads", isDirectory: true)
) -> MistralTranscriptionProvider {
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [StubURLProtocol.self]
  return MistralTranscriptionProvider(
    session: URLSession(configuration: configuration),
    multipartStaging: MultipartUploadStaging(directory: multipartDirectory)
  )
}

private actor MistralRequestObserver {
  private var request: URLRequest?

  func store(request: URLRequest) {
    self.request = request
  }

  func capturedRequest() -> URLRequest? {
    request
  }

}

