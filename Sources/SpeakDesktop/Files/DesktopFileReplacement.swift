import CRecordingFileSupport
import Foundation

extension DesktopFilePublication {
    /// Atomically replaces a chosen sibling name, unlike exclusive `commit`.
    /// Failure preserves both names; success consumes staging. No copy fallback.
    public static func replace(staging: URL, destination: URL) throws {
        let source = try replacementFile(staging)
        let target = try replacementFile(destination)
        guard source != target, source.deletingLastPathComponent() == target.deletingLastPathComponent() else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try Task.checkCancellation()
        let status = try source.withUnsafeFileSystemRepresentation { sourcePath in
            try target.withUnsafeFileSystemRepresentation { targetPath in
                guard let sourcePath, let targetPath else { throw CocoaError(.fileWriteInvalidFileName) }
                return jsti_file_replace(sourcePath, targetPath)
            }
        }
        guard status == 0 else {
            #if os(Windows)
            let domain = "JSTIFileReplacementWindows"
            #else
            let domain = NSPOSIXErrorDomain
            #endif
            throw NSError(domain: domain, code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "Could not replace the chosen file (native error \(status))."
            ])
        }
    }

    static func replacementFile(_ url: URL) throws -> URL {
        guard url.isFileURL && !url.hasDirectoryPath && !url.path.utf8.contains(0)
            && !url.absoluteString.lowercased().contains("%00")
            && (url.host == nil || url.host == "" || url.host?.lowercased() == "localhost") else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        return url.standardizedFileURL
    }
}
