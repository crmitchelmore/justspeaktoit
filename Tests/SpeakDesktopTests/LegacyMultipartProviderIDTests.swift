import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakCore
import SpeakTestSupport
import XCTest

final class LegacyMultipartProviderIDTests: XCTestCase {
    override func tearDown() { StubURLProtocol.reset(); super.tearDown() }

    #if !os(Windows)
    func testPublicLegacyInitializerKeepsFacadeNormalisationAndCleanup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("speech.wav")
        let audio = Data([1, 2, 3])
        try audio.write(to: source)
        let directory = root.appendingPathComponent("uploads")
        let staging = MultipartUploadStaging(directory: directory)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = OpenAICompatibleBatchTranscriptionClient(session: session, staging: staging)
        for (provider, prefix) in [
            ("fixture", "fixture"), ("OpenAI", "openai"), ("provider.v2", "provider_v2"),
            ("fournisseuré", "fournisseur__"), (String(repeating: "p", count: 65), String(repeating: "p", count: 64))
        ] {
            StubURLProtocol.handler = { request in
                let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                XCTAssertEqual(files.count, 1)
                let body = try XCTUnwrap(files.first)
                XCTAssertTrue(body.lastPathComponent.hasPrefix(prefix + "-"))
                staging.purgeStaleUploads(now: .distantFuture)
                XCTAssertNotNil(try Data(contentsOf: body).range(of: audio), "the facade must retain its active claim")
                return .ok(Data("{}".utf8), url: request.url!)
            }
            _ = try await client.upload(
                request: URLRequest(url: URL(string: "https://example.invalid/transcribe")!), fields: [],
                file: .init(fieldName: "file", filename: "speech.wav", mimeType: "audio/wav", sourceURL: source),
                providerID: provider
            )
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        }
        XCTAssertEqual(try Data(contentsOf: source), audio)
    }

    #endif

    func testDirectSharedInitializerStillRejectsNonCanonicalProviderIDsBeforeUpload() async throws {
        let fixture = DesktopMultipartFixture()
        defer { fixture.remove() }
        StubURLProtocol.handler = { request in
            XCTFail("Non-canonical shared-staging IDs must fail before transport")
            return .ok(Data(), url: request.url!)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = OpenAICompatibleBatchTranscriptionClient(session: session, sharedStaging: fixture.staging)
        for provider in ["OpenAI", "provider.v2", "fournisseuré", String(repeating: "p", count: 65)] {
            do {
                _ = try await client.upload(
                    request: URLRequest(url: URL(string: "https://example.invalid/transcribe")!), fields: [],
                    file: .init(fieldName: "file", filename: "missing.wav", mimeType: "audio/wav",
                                sourceURL: fixture.directory.appendingPathComponent("missing.wav")),
                    providerID: provider
                )
                XCTFail("Expected strict shared-staging rejection for \(provider)")
            } catch let error as CocoaError {
                XCTAssertEqual(error.code, .fileWriteInvalidFileName)
            }
        }
        XCTAssertTrue((try? FileManager.default.contentsOfDirectory(atPath: fixture.directory.path))?.isEmpty ?? true)
    }
}
