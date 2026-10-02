import Foundation
import SpeakCore
import CWindowsSupport

extension WindowsNative {
    static func stagingSelfTest() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let staging = uploadStaging(directory: parent.appendingPathComponent("Uploads"), selfTestDiagnostics: true)
        let body = try staging.createUploadBodyFile(providerID: "synthetic")
        let file = try FileHandle(forWritingTo: body)
        do { try file.write(contentsOf: Data([1, 2, 3])); try file.close() } catch { try? file.close(); throw error }
        traceSyntheticStagingURL(body, phase: "before removal")
        staging.removeUploadBodyFile(at: body)
        guard !FileManager.default.fileExists(atPath: body.path) else {
            throw WindowsNativeError(message: "The synthetic private upload was not removed.")
        }
    }

    static func uploadStaging(directory: URL, selfTestDiagnostics: Bool = false) -> SharedMultipartUploadStaging {
        SharedMultipartUploadStaging(
            directory: directory,
            securityPolicy: .init(
                prepareDirectory: { url, _ in
                    try url.path.withCString { path in
                        try checked { jsti_private_directory_prepare(path, $0, $1) }
                    }
                },
                createFile: { url, _ in
                    if selfTestDiagnostics { traceSyntheticStagingURL(url, phase: "before creation") }
                    try url.path.withCString { path in
                        try checked { jsti_private_file_create(path, $0, $1) }
                    }
                    return true
                }
            ),
            report: { event in
                if selfTestDiagnostics { print("Synthetic private staging event: \(event)") }
            }
        )
    }

    /// Called only for this self-test's newly owned synthetic path. Normal
    /// uploads keep their paths and deletion diagnostics out of command output.
    private static func traceSyntheticStagingURL(_ url: URL, phase: String) {
        let key = url.standardizedFileURL.resolvingSymlinksInPath().path.lowercased()
        let location = url.deletingLastPathComponent().standardizedFileURL
            .resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent).path.lowercased()
        print("Synthetic private staging \(phase): url=\(url.absoluteString)")
        print("Synthetic private staging \(phase): path=\(url.path)")
        print("Synthetic private staging \(phase): key=\(key)")
        print("Synthetic private staging \(phase): location=\(location)")
    }

}
