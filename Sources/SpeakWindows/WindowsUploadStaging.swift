import Foundation
import SpeakCore
import CWindowsSupport

extension WindowsNative {
    static func stagingSelfTest() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let staging = uploadStaging(directory: parent.appendingPathComponent("Uploads"))
        let body = try staging.createUploadBodyFile(providerID: "synthetic")
        let file = try FileHandle(forWritingTo: body)
        do { try file.write(contentsOf: Data([1, 2, 3])); try file.close() } catch { try? file.close(); throw error }
        staging.removeUploadBodyFile(at: body)
        guard !FileManager.default.fileExists(atPath: body.path) else {
            throw WindowsNativeError(message: "The synthetic private upload was not removed.")
        }
    }

    static func uploadStaging(directory: URL) -> SharedMultipartUploadStaging {
        SharedMultipartUploadStaging(
            directory: directory,
            securityPolicy: .init(
                prepareDirectory: { url, _ in
                    try url.path.withCString { path in
                        try checked { jsti_private_directory_prepare(path, $0, $1) }
                    }
                },
                createFile: { url, _ in
                    try url.path.withCString { path in
                        try checked { jsti_private_file_create(path, $0, $1) }
                    }
                    return true
                }
            )
        )
    }

}
