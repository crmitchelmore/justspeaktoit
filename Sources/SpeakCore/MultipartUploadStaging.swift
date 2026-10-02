import Foundation

#if !os(Windows)
/// Retains the Apple staging API while sharing active claims with the portable
/// clients. Windows callers must supply their native ACL staging policy.
public final class MultipartUploadStaging: @unchecked Sendable {
    public static let shared = MultipartUploadStaging()
    public static let defaultStalenessThreshold = SharedMultipartUploadStaging.defaultStalenessThreshold
    /// The same owned staging store is shared with native app targets outside SwiftPM.
    public let sharedStore: SharedMultipartUploadStaging

    public init(
        directory: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent(ReleaseTrain.current.namespace("speak-multipart-uploads"), isDirectory: true),
        stalenessThreshold: TimeInterval = MultipartUploadStaging.defaultStalenessThreshold,
        fileManager: FileManager = .default
    ) {
        sharedStore = SharedMultipartUploadStaging(
            directory: directory, securityPolicy: .posix,
            stalenessThreshold: stalenessThreshold.isFinite && stalenessThreshold > 0
                ? stalenessThreshold : Self.defaultStalenessThreshold,
            fileManager: fileManager,
            report: Self.report
        )
    }

    public func createUploadBodyFile(providerID: String) throws -> URL {
        try sharedStore.createUploadBodyFile(providerID: Self.safeFileNamePrefix(providerID))
    }

    public func removeUploadBodyFile(at url: URL) { sharedStore.removeUploadBodyFile(at: url) }
    public func purgeStaleUploads(now: Date = Date()) { sharedStore.purgeStaleUploads(now: now) }

    static func safeFileNamePrefix(_ providerID: String) -> String {
        let safe = providerID.lowercased().utf8.map { byte -> UInt8 in
            (97...122).contains(byte) || (48...57).contains(byte) || byte == 45 || byte == 95 ? byte : 95
        }
        return safe.isEmpty ? "provider" : (String(bytes: safe.prefix(64), encoding: .utf8) ?? "provider")
    }

    private static func report(_ event: SharedMultipartUploadStaging.Event) {
        #if !SPEAK_PORTABLE_CORE
        let logger = SpeakLogger.logger(category: "MultipartUploadStaging")
        switch event {
        case .purged(let filename):
            logger.info("Purged stale multipart upload body \(filename, privacy: .public)")
        case .removalFailed(let filename, let message):
            logger.error(
                "Failed to remove multipart upload body \(filename, privacy: .public): \(message, privacy: .public)"
            )
        case .directoryPreparationFailed(let message):
            logger.error("Failed to secure multipart upload directory: \(message, privacy: .public)")
        }
        #endif
    }
}
#endif
