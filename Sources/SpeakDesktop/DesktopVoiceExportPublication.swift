import Foundation

/// Writes only a new sibling, then replaces the chosen name at one native commit point.
public enum DesktopVoiceExportPublication {
    public static func write(_ data: Data, to destination: URL) throws {
        let destination = try DesktopFilePublication.replacementFile(destination)
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".voice-export-\(UUID().uuidString).partial")
        do {
            try Task.checkCancellation()
            try data.write(to: staging, options: .withoutOverwriting)
            try Task.checkCancellation()
            try DesktopFilePublication.replace(staging: staging, destination: destination)
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
}
