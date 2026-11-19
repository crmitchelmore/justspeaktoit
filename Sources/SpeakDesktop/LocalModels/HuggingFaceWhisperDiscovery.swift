import Foundation
import SpeakCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol HuggingFaceModelMetadataTransport: Sendable {
    /// Only the canonical API endpoint is accepted. No credentials are used.
    func metadata(at url: URL) async throws -> Data
}

public struct HuggingFaceModelMetadataHTTP: HuggingFaceModelMetadataTransport {
    private let session: URLSession?
    public init(session: URLSession? = nil) { self.session = session }

    public func metadata(at url: URL) async throws -> Data {
        guard url.scheme == "https", url.host == "huggingface.co", url.port == nil,
              url.user == nil, url.password == nil, url.path.hasPrefix("/api/models/") else {
            throw HuggingFaceWhisperError.invalidMetadata
        }
        let configuration = self.session?.configuration ?? URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let result = try await BoundedHTTPExchange.perform(
            request, session: session, limit: HuggingFaceWhisperDiscovery.maximumMetadataBytes, deadline: .seconds(20)
        )
        guard result.response.statusCode == 200, result.response.url == url,
              result.response.mimeType == "application/json" else {
            throw HuggingFaceWhisperError.invalidMetadata
        }
        return result.body
    }
}

/// Resolves a mutable repository head, then independently reads that exact
/// immutable commit. The two records must agree before any import is offered.
public struct HuggingFaceWhisperDiscovery: Sendable {
    public static let maximumMetadataBytes = 2 * 1_024 * 1_024
    public let transport: any HuggingFaceModelMetadataTransport

    public init(transport: any HuggingFaceModelMetadataTransport = HuggingFaceModelMetadataHTTP()) {
        self.transport = transport
    }

    public func discover(repository: String, filename: String) async throws -> HuggingFaceWhisperModel {
        try HuggingFaceWhisperModel.validateInput(repository: repository, filename: filename)
        let file = try await HuggingFaceArtifactMetadata.discover(
            repository: repository, filename: filename, transport: transport
        ) {
            _ = try HuggingFaceWhisperModel(
                repository: repository, filename: filename, revision: $0.revision,
                byteCount: $0.byteCount, sha256: $0.sha256, license: $0.license
            )
        }
        return try HuggingFaceWhisperModel(
            repository: repository, filename: filename, revision: file.revision, byteCount: file.byteCount,
            sha256: file.sha256, license: file.license
        )
    }
}
