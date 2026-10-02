import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A provider-neutral multipart uploader for batch transcription endpoints.
///
/// Callers retain ownership of the endpoint, authentication, fields, and response
/// decoding. The client only stages and uploads a bounded-memory multipart body.
public struct OpenAICompatibleBatchTranscriptionClient: Sendable {
  public struct FormField: Sendable, Equatable {
    public let name: String
    public let value: String

    public init(name: String, value: String) {
      self.name = name
      self.value = value
    }
  }

  public struct FilePart: Sendable, Equatable {
    public let fieldName: String
    public let filename: String
    public let mimeType: String
    public let sourceURL: URL

    public init(fieldName: String, filename: String, mimeType: String, sourceURL: URL) {
      self.fieldName = fieldName
      self.filename = filename
      self.mimeType = mimeType
      self.sourceURL = sourceURL
    }
  }

  private static let copyChunkSize = 1024 * 1024

  private let staging: SharedMultipartUploadStaging
  private let performUpload: @Sendable (URLRequest, URL) async throws -> (Data, URLResponse)

  #if !os(Windows)
  public init(session: URLSession = .shared, staging: MultipartUploadStaging = .shared) {
    self.init(session: session, sharedStaging: staging.sharedStore)
  }
  #endif

  public init(session: URLSession = .shared, sharedStaging: SharedMultipartUploadStaging) {
    self.staging = sharedStaging
    self.performUpload = { request, fileURL in
      try await session.upload(for: request, fromFile: fileURL)
    }
  }

  #if !os(Windows)
  init(
    staging: MultipartUploadStaging,
    performUpload: @escaping @Sendable (URLRequest, URL) async throws -> (Data, URLResponse)
  ) {
    self.staging = staging.sharedStore
    self.performUpload = performUpload
  }

  #endif

  public func upload(
    request callerRequest: URLRequest,
    fields: [FormField],
    file: FilePart,
    providerID: String
  ) async throws -> (data: Data, response: HTTPURLResponse) {
    try Task.checkCancellation()
    let boundary = "Boundary-\(UUID().uuidString)"
    var request = callerRequest
    request.httpMethod = request.httpMethod ?? "POST"
    request.httpBody = nil
    request.httpBodyStream = nil
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

    try Self.validateProviderID(providerID)
    let bodyURL = try self.staging.createUploadBodyFile(providerID: providerID)
    defer { self.staging.removeUploadBodyFile(at: bodyURL) }
    let buildTask = Task.detached {
      try Self.writeBody(to: bodyURL, boundary: boundary, fields: fields, file: file)
    }

    try await withTaskCancellationHandler {
      try await buildTask.value
    } onCancel: {
      buildTask.cancel()
    }

    try Task.checkCancellation()
    let (data, response) = try await self.performUpload(request, bodyURL)
    // Cancellation is cooperative: an upload that completes while its task is
    // being cancelled must not be reported (and then decoded) as a success.
    try Task.checkCancellation()
    guard let http = response as? HTTPURLResponse else {
      throw TranscriptionProviderError.invalidResponse
    }
    guard (200..<300).contains(http.statusCode) else {
      let body = String(data: data, encoding: .utf8) ?? "<no-body>"
      throw TranscriptionProviderError.httpError(http.statusCode, body)
    }
    return (data, http)
  }

  private static func writeBody(
    to destinationURL: URL,
    boundary: String,
    fields: [FormField],
    file: FilePart
  ) throws {
    try Self.validateToken(file.fieldName)
    try Self.validateToken(file.mimeType)
    for field in fields {
      try Self.validateToken(field.name)
    }

    let output = try FileHandle(forWritingTo: destinationURL)
    defer { try? output.close() }

    for field in fields {
      try Task.checkCancellation()
      let header = "--\(boundary)\r\n"
        + "Content-Disposition: form-data; name=\"\(field.name)\"\r\n\r\n"
        + "\(field.value)\r\n"
      try output.write(contentsOf: Data(header.utf8))
    }

    let filename = Self.escapedFilename(file.filename)
    let fileHeader = "--\(boundary)\r\n"
      + "Content-Disposition: form-data; name=\"\(file.fieldName)\"; filename=\"\(filename)\"\r\n"
      + "Content-Type: \(file.mimeType)\r\n\r\n"
    try output.write(contentsOf: Data(fileHeader.utf8))

    let input = try FileHandle(forReadingFrom: file.sourceURL)
    defer { try? input.close() }
    while true {
      try Task.checkCancellation()
      let chunk = try input.read(upToCount: Self.copyChunkSize) ?? Data()
      guard !chunk.isEmpty else { break }
      try output.write(contentsOf: chunk)
    }
    try Task.checkCancellation()
    try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
  }

  private static func validateToken(_ token: String) throws {
    guard !token.isEmpty,
          token.unicodeScalars.allSatisfy({
            $0.value >= 0x21 && $0.value <= 0x7E && $0.value != 0x22 && $0.value != 0x5C
          })
    else {
      throw CocoaError(.fileWriteInvalidFileName)
    }
  }

  private static func validateProviderID(_ providerID: String) throws {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
    guard !providerID.isEmpty, providerID.unicodeScalars.allSatisfy(allowed.contains) else {
      throw CocoaError(.fileWriteInvalidFileName)
    }
  }

  /// Drops every control and line-break scalar (not only CR/LF), so nothing can
  /// end or corrupt the `Content-Disposition` header, then escapes `\` and `"`
  /// for the quoted-string parameter.
  static func escapedFilename(_ filename: String) -> String {
    let dropped = CharacterSet.controlCharacters.union(.newlines)
    var escaped = String.UnicodeScalarView()
    for scalar in filename.unicodeScalars where !dropped.contains(scalar) {
      if scalar == "\\" || scalar == "\"" {
        escaped.append("\\")
      }
      escaped.append(scalar)
    }
    return String(escaped)
  }
}
