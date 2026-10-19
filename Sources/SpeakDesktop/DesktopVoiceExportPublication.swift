import Foundation
#if os(Windows)
import WinSDK
#elseif os(Linux)
import Glibc
#else
import Darwin
#endif

/// Writes only a new sibling, then replaces the chosen name at one native commit point.
public enum DesktopVoiceExportPublication {
    public static func write(_ data: Data, to destination: URL) throws {
        guard destination.isFileURL, !destination.path.utf8.contains(0) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".voice-export-\(UUID().uuidString).partial")
        do {
            try Task.checkCancellation()
            try data.write(to: staging, options: .withoutOverwriting)
            try Task.checkCancellation()
            try replace(staging, destination)
        } catch {
            if FileManager.default.fileExists(atPath: staging.path) {
                do { try FileManager.default.removeItem(at: staging) } catch let cleanup {
                    throw NSError(domain: "JSTIVoiceExport", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "Voice export failed: \(error.localizedDescription) "
                            + "Temporary file cleanup failed: \(cleanup.localizedDescription)"
                    ])
                }
            }
            throw error
        }
    }

    private static func replace(_ source: URL, _ destination: URL) throws {
        #if os(Windows)
        guard let fromPath = source.withUnsafeFileSystemRepresentation({ $0.map(String.init(cString:)) }),
              let toPath = destination.withUnsafeFileSystemRepresentation({ $0.map(String.init(cString:)) }) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let sourcePath = Array(fromPath.utf16) + [0]
        let destinationPath = Array(toPath.utf16) + [0]
        let result = sourcePath.withUnsafeBufferPointer { from in
            destinationPath.withUnsafeBufferPointer { target in
                let moved = MoveFileExW(from.baseAddress, target.baseAddress,
                    DWORD(MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) != 0
                return (moved, moved ? DWORD(0) : GetLastError())
            }
        }
        guard result.0 else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(result.1)) }
        #else
        guard rename(source.path, destination.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        #endif
    }
}
