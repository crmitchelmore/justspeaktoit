import Foundation
#if os(Windows)
import ucrt
#endif

/// Publishes a caller-owned sibling staging file exclusively.
/// A failed publication keeps staging intact; a successful one consumes it.
public enum DesktopFilePublication {
    public static func commit(staging: URL, destination: URL) throws {
        guard staging.isFileURL, destination.isFileURL,
              !staging.path.utf8.contains(0), !destination.path.utf8.contains(0),
              staging.standardizedFileURL != destination.standardizedFileURL,
              staging.deletingLastPathComponent().standardizedFileURL ==
                destination.deletingLastPathComponent().standardizedFileURL else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        #if os(Windows)
        // Foundation's Windows linkItem can leave a symbolic link to staging.
        // The Windows CRT refuses existing destinations. Sibling paths prevent
        // its cross-device copy behavior and keep publication a native rename.
        guard let source = nativePath(staging), let target = nativePath(destination) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let sourceWide = Array(source.utf16) + [0]
        let targetWide = Array(target.utf16) + [0]
        let result = sourceWide.withUnsafeBufferPointer { from in
            targetWide.withUnsafeBufferPointer { targetBuffer in
                let moved = _wrename(from.baseAddress, targetBuffer.baseAddress) == 0
                return (moved, moved ? Int32(0) : _errno().pointee)
            }
        }
        guard result.0 else {
            throw NSError(domain: "JSTIFilePublicationWindows", code: Int(result.1), userInfo: [
                NSLocalizedDescriptionKey: "Could not publish the staged file (Windows runtime error \(result.1))."
            ])
        }
        #else
        // Commit exclusively, then leave only the independent destination inode.
        try FileManager.default.linkItem(at: staging, to: destination)
        do {
            try FileManager.default.removeItem(at: staging)
        } catch {
            throw DesktopFilePublicationCleanupFailure(destination: destination, cleanup: error)
        }

        #endif
    }

    #if os(Windows)
    private static func nativePath(_ url: URL) -> String? {
        url.withUnsafeFileSystemRepresentation { $0.map(String.init(cString:)) }
    }
    #endif
}

/// Publication succeeded, but staging could not be removed; both names remain.
public struct DesktopFilePublicationCleanupFailure: LocalizedError {
    public let destination: URL
    public let cleanup: Error

    public var errorDescription: String? {
        "The file was published as \(destination.lastPathComponent), but staging cleanup failed: "
            + cleanup.localizedDescription + " The published file was kept."
    }
}
