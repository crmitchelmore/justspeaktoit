import Foundation
import XCTest

@testable import SpeakCore

final class OpenAICompatibleBatchTranscriptionClientTests: XCTestCase {
  func testUpload_writesOrderedFieldsAndExactFileBytesAndCleansUp() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("clip\r\n\\\".m4a")
    var audio = Data(repeating: 0, count: 2 * 1024 * 1024 + 17)
    audio.replaceSubrange(0..<5, with: [0, 1, 2, 0, 255])
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try audio.write(to: source)

    let capture = UploadCapture()
    let staging = MultipartUploadStaging(directory: directory.appendingPathComponent("staging"))
    let client = OpenAICompatibleBatchTranscriptionClient(staging: staging) { request, bodyURL in
      staging.purgeStaleUploads(now: Date().addingTimeInterval(7_200))
      let activeBodyWasProtected = FileManager.default.fileExists(atPath: bodyURL.path)
      try await capture.store(request: request, body: Data(contentsOf: bodyURL), bodyURL: bodyURL)
      await capture.storeActiveBodyWasProtected(activeBodyWasProtected)
      return (
        Data("ok".utf8),
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      )
    }
    var request = URLRequest(url: URL(string: "https://example.test/transcriptions")!)
    request.httpMethod = "POST"
    request.setValue("secret", forHTTPHeaderField: "xi-api-key")
    request.setValue("multipart/form-data; boundary=stale", forHTTPHeaderField: "Content-Type")
    request.httpBody = Data("stale body".utf8)

    let result = try await client.upload(
      request: request,
      fields: [.init(name: "model", value: "one"), .init(name: "model", value: "two")],
      file: .init(fieldName: "file", filename: source.lastPathComponent, mimeType: "audio/m4a", sourceURL: source),
      providerID: "fixture"
    )

    XCTAssertEqual(result.data, Data("ok".utf8))
    let captured = await capture.value()
    XCTAssertEqual(captured.request?.url, request.url)
    XCTAssertEqual(captured.request?.value(forHTTPHeaderField: "xi-api-key"), "secret")
    XCTAssertNil(captured.request?.value(forHTTPHeaderField: "Authorization"))
    XCTAssertNil(captured.request?.httpBody)
    XCTAssertNil(captured.request?.httpBodyStream)
    let contentType = try XCTUnwrap(captured.request?.value(forHTTPHeaderField: "Content-Type"))
    let boundary = try XCTUnwrap(contentType.split(separator: "boundary=").last.map(String.init))
    let body = try XCTUnwrap(captured.body)
    let first = try XCTUnwrap(body.range(of: Data("\r\none\r\n".utf8)))
    let second = try XCTUnwrap(body.range(of: Data("\r\ntwo\r\n".utf8)))
    XCTAssertLessThan(first.lowerBound, second.lowerBound)
    XCTAssertNotNil(body.range(of: audio))
    XCTAssertNotNil(body.range(of: Data("filename=\"clip\\\\\\\".m4a\"".utf8)))
    XCTAssertTrue(body.starts(with: Data("--\(boundary)\r\n".utf8)))
    XCTAssertTrue(body.ends(with: Data("\r\n--\(boundary)--\r\n".utf8)))
    XCTAssertEqual(captured.activeBodyWasProtected, true)
    XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(captured.bodyURL).path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
  }

  func testUpload_non2xxPreservesResponseBodyAndCleansUp() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let source = directory.appendingPathComponent("audio.m4a")
    try Data("audio".utf8).write(to: source)
    let capture = UploadCapture()
    let client = OpenAICompatibleBatchTranscriptionClient(
      staging: MultipartUploadStaging(directory: directory.appendingPathComponent("staging"))
    ) { request, bodyURL in
      await capture.storeURL(bodyURL)
      return (
        Data("provider detail".utf8),
        HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!
      )
    }

    do {
      _ = try await client.upload(
        request: URLRequest(url: URL(string: "https://example.test")!),
        fields: [],
        file: .init(fieldName: "file", filename: "audio.m4a", mimeType: "audio/m4a", sourceURL: source),
        providerID: "fixture"
      )
      XCTFail("Expected HTTP error")
    } catch let error as TranscriptionProviderError {
      XCTAssertEqual(error, .httpError(429, "provider detail"))
    }
    let bodyURL = await capture.value().bodyURL
    XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(bodyURL).path))
  }

  func testUpload_missingSourceCleansPartialBodyWithoutCallingUploader() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let stagingDirectory = directory.appendingPathComponent("staging")
    let client = OpenAICompatibleBatchTranscriptionClient(
      staging: MultipartUploadStaging(directory: stagingDirectory)
    ) { _, _ in
      XCTFail("Uploader must not run")
      return (
        Data(),
        URLResponse(
          url: URL(string: "https://example.test")!,
          mimeType: nil,
          expectedContentLength: 0,
          textEncodingName: nil
        )
      )
    }

    await XCTAssertThrowsErrorAsync {
      _ = try await client.upload(
        request: URLRequest(url: URL(string: "https://example.test")!),
        fields: [],
        file: .init(
          fieldName: "file",
          filename: "missing.m4a",
          mimeType: "audio/m4a",
          sourceURL: directory.appendingPathComponent("missing.m4a")
        ),
        providerID: "fixture"
      )
    }
    let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: stagingDirectory.path)) ?? []
    XCTAssertTrue(leftovers.isEmpty)
  }

  func testUpload_preCancelledTaskDoesNotStageOrCallUploader() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let source = directory.appendingPathComponent("audio.m4a")
    try Data("audio".utf8).write(to: source)
    let stagingDirectory = directory.appendingPathComponent("staging")
    let uploaderCalled = BooleanCapture()
    let client = OpenAICompatibleBatchTranscriptionClient(
      staging: MultipartUploadStaging(directory: stagingDirectory)
    ) { _, _ in
      await uploaderCalled.setTrue()
      return (
        Data(),
        URLResponse(
          url: URL(string: "https://example.test")!,
          mimeType: nil,
          expectedContentLength: 0,
          textEncodingName: nil
        )
      )
    }
    let task = Task {
      try await client.upload(
        request: URLRequest(url: URL(string: "https://example.test")!),
        fields: [],
        file: .init(fieldName: "file", filename: "audio.m4a", mimeType: "audio/m4a", sourceURL: source),
        providerID: "fixture"
      )
    }
    task.cancel()

    do {
      _ = try await task.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {}
    let wasUploaderCalled = await uploaderCalled.value()
    XCTAssertFalse(wasUploaderCalled)
    let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: stagingDirectory.path)) ?? []
    XCTAssertTrue(leftovers.isEmpty)
  }

  func testUpload_cancelledUploaderRemovesStagedBodyAndKeepsSource() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let source = directory.appendingPathComponent("audio.m4a")
    try Data("audio".utf8).write(to: source)
    let stagingDirectory = directory.appendingPathComponent("staging")
    let client = OpenAICompatibleBatchTranscriptionClient(
      staging: MultipartUploadStaging(directory: stagingDirectory)
    ) { _, _ in
      throw CancellationError()
    }

    do {
      _ = try await client.upload(
        request: URLRequest(url: URL(string: "https://example.test")!),
        fields: [],
        file: .init(fieldName: "file", filename: "audio.m4a", mimeType: "audio/m4a", sourceURL: source),
        providerID: "fixture"
      )
      XCTFail("Expected cancellation")
    } catch is CancellationError {}
    let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: stagingDirectory.path)) ?? []
    XCTAssertTrue(leftovers.isEmpty)
    XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("bounded-multipart-tests-\(UUID().uuidString)", isDirectory: true)
  }
}

private actor UploadCapture {
  private var request: URLRequest?
  private var body: Data?
  private var bodyURL: URL?
  private var activeBodyWasProtected: Bool?

  func store(request: URLRequest, body: Data, bodyURL: URL) {
    self.request = request
    self.body = body
    self.bodyURL = bodyURL
  }

  func storeURL(_ bodyURL: URL) {
    self.bodyURL = bodyURL
  }

  func storeActiveBodyWasProtected(_ value: Bool) {
    self.activeBodyWasProtected = value
  }

  func value() -> (request: URLRequest?, body: Data?, bodyURL: URL?, activeBodyWasProtected: Bool?) {
    (request, body, bodyURL, activeBodyWasProtected)
  }
}

private actor BooleanCapture {
  private var storedValue = false

  func setTrue() {
    self.storedValue = true
  }

  func value() -> Bool {
    self.storedValue
  }
}

private func XCTAssertThrowsErrorAsync(
  _ expression: () async throws -> Void,
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  do {
    try await expression()
    XCTFail("Expected error", file: file, line: line)
  } catch {}
}
