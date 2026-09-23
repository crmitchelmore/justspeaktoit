import Foundation
import SpeakCore

/// Preserves the native app API and OS logging while both desktop platforms
/// share the same claim registry, streamed-upload files and stale cleanup.
final class MultipartUploadStaging: @unchecked Sendable {
    static let shared = MultipartUploadStaging()
    static let defaultStalenessThreshold = SharedMultipartUploadStaging.defaultStalenessThreshold
    let sharedStore: SharedMultipartUploadStaging

    init(
        directory: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent(ReleaseTrain.current.namespace("speak-multipart-uploads"), isDirectory: true),
        stalenessThreshold: TimeInterval = MultipartUploadStaging.defaultStalenessThreshold,
        fileManager: FileManager = .default
    ) {
        let logger = SpeakLogger.logger(category: "MultipartUploadStaging")
        sharedStore = SharedMultipartUploadStaging(
            directory: directory, securityPolicy: .posix,
            stalenessThreshold: stalenessThreshold, fileManager: fileManager
        ) { event in
            switch event {
            case .purged(let filename):
                logger.info("Purged stale multipart upload body \(filename, privacy: .public)")
            case .removalFailed(let filename, let message):
                logger.error("""
                    Failed to remove multipart upload body \(filename, privacy: .public): \(message, privacy: .public)
                    """)
            case .directoryPreparationFailed(let message):
                logger.error("Failed to secure multipart upload directory: \(message, privacy: .public)")
            }
        }
    }

    func createUploadBodyFile(providerID: String) throws -> URL {
        try sharedStore.createUploadBodyFile(providerID: providerID)
    }

    func removeUploadBodyFile(at url: URL) { sharedStore.removeUploadBodyFile(at: url) }
    func purgeStaleUploads(now: Date = Date()) { sharedStore.purgeStaleUploads(now: now) }
}
