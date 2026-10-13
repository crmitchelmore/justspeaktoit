import Foundation
#if os(Windows)
import WinSDK
#endif

/// Publishes a caller-owned staged file exclusively on the same filesystem.
/// A failed publication keeps staging intact; a successful one consumes it.
public enum DesktopFilePublication {
    public static func commit(staging: URL, destination: URL) throws {
        guard staging.isFileURL, destination.isFileURL,
              !staging.path.utf8.contains(0), !destination.path.utf8.contains(0),
              staging.standardizedFileURL != destination.standardizedFileURL else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        #if os(Windows)
        // Foundation's Windows linkItem can leave a symbolic link to staging.
        // A same-directory native rename is exclusive without REPLACE_EXISTING.
        guard let source = nativePath(staging), let target = nativePath(destination) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let sourceWide = Array(source.utf16) + [0]
        let targetWide = Array(target.utf16) + [0]
        let result = sourceWide.withUnsafeBufferPointer { from in
            targetWide.withUnsafeBufferPointer { targetBuffer in
                let moved = MoveFileExW(from.baseAddress, targetBuffer.baseAddress, DWORD(MOVEFILE_WRITE_THROUGH)) != 0
                return (moved, moved ? DWORD(0) : GetLastError())
            }
        }
        guard result.0 else {
            throw NSError(domain: "JSTIFilePublicationWindows", code: Int(result.1), userInfo: [
                NSLocalizedDescriptionKey: "Could not publish the staged file (Windows error \(result.1))."
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
