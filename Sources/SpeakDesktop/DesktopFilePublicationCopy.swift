import Foundation

extension DesktopFilePublication {
    /// The native operation copies into private destination-side staging and
    /// publishes atomically without overwriting. It always retains the source.
    public struct Copy: Sendable {
        let publish: @Sendable (URL, URL) throws -> Void

        public init(publish: @escaping @Sendable (URL, URL) throws -> Void) {
            self.publish = publish
        }

    }

    /// The destination is already published; callers must not delete or retry it.
    public struct CopyCompletionFailure: LocalizedError, Sendable {
        public let destination: URL
        public let detail: String

        public init(destination: URL, detail: String) {
            self.destination = destination
            self.detail = detail
        }

        public var errorDescription: String? {
            "The file was saved as \(destination.lastPathComponent), but publication cleanup or durability "
                + "could not be confirmed: \(detail) The published file was kept."
        }
    }

    /// Synchronous I/O: hosts run this in an owned cancellable worker task, not
    /// on the UI actor or the native settings admission queue.
    public static func copy(source: URL, destination: URL, using operation: Copy) throws {
        guard validLocalFile(source), validLocalFile(destination),
              source.standardizedFileURL != destination.standardizedFileURL else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try Task.checkCancellation()
        try operation.publish(source, destination)
    }

    private static func validLocalFile(_ url: URL) -> Bool {
        url.isFileURL && !url.hasDirectoryPath && !url.path.utf8.contains(0)
            && !url.absoluteString.lowercased().contains("%00")
            && (url.host == nil || url.host == "" || url.host?.lowercased() == "localhost")
    }
}
