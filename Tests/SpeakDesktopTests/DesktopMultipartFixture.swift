import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakCore
import XCTest

/// Injected storage for synthetic test bytes. Windows ACL enforcement is tested
/// by the native host; this fixture intentionally exercises the policy boundary.
struct DesktopMultipartFixture: Sendable {
    let directory: URL
    let staging: SharedMultipartUploadStaging

    init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("desktop-multipart-tests-\(UUID().uuidString)", isDirectory: true)
        staging = SharedMultipartUploadStaging(directory: directory, securityPolicy: .init(
            prepareDirectory: { directory, manager in
                try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            },
            createFile: { url, manager in manager.createFile(atPath: url.path, contents: nil) }
        ))
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    /// Read the production upload's owned file while the request is dispatched.
    /// Corelibs URLProtocol does not expose an upload-from-file body stream.
    func body(for request: URLRequest) throws -> Data {
        XCTAssertNil(request.httpBody)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1, "Exactly one owned body must belong to this request")
        let file = try XCTUnwrap(files.count == 1 ? files.first : nil)
        let body = try Data(contentsOf: file)
        let contentType = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))
        let prefix = "multipart/form-data; boundary="
        XCTAssertTrue(contentType.hasPrefix(prefix))
        let boundary = String(contentType.dropFirst(prefix.count))
        XCTAssertFalse(boundary.isEmpty)
        XCTAssertTrue(body.starts(with: Data("--\(boundary)\r\n".utf8)))
        let closingBoundary = Data("--\(boundary)--\r\n".utf8)
        XCTAssertEqual(body.suffix(closingBoundary.count), closingBoundary)
        return body
    }
}
