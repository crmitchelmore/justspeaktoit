import Foundation
import SpeakCore

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
}
