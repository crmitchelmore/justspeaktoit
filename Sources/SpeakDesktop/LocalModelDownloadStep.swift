import Foundation
import SpeakCore

/// Streams a pinned archive into an exclusively created private file while
/// hashing it, refuses a digest mismatch before anything is expanded, then
/// installs from that file. The partial download is removed on every outcome.
struct LocalModelDownloadStep: Sendable {
    let operations: LocalModelStoreOperations
    let transport: LocalModelDownloadTransport

    func run(
        _ package: LocalModelPackage, cancellation: LocalModelCancellation,
        progress: @escaping @Sendable (LocalModelInstallState) -> Void
    ) async throws -> LocalModelInstallation {
        let operations = operations
        let archiveURL = operations.newDownloadURL(package)
        let sink = try await LocalModelBlockingWork.run(name: "Local model download file") {
            _ = try operations.preparePackageDirectory(package)
            return DownloadSink(
                writer: try operations.fileSystem.createFile(archiveURL), hasher: try operations.digests.makeSHA256(),
                total: package.archive.byteCount, cancellation: cancellation, progress: progress
            )
        }
        let request = LocalModelDownloadRequest(
            url: package.archive.url, expectedByteCount: package.archive.byteCount,
            allowedHosts: LocalModelURLSessionTransport.allowedHosts(for: package.archive.url)
        )
        do {
            try await transport.download(request) { try sink.append($0) }
            try cancellation.check()
            try await LocalModelBlockingWork.run(name: "Local model download finish") {
                try sink.finish(expectedSHA256: package.archive.sha256)
            }
            let installation = try await LocalModelBlockingWork.run(name: "Local model install") {
                try operations.installArchive(
                    at: archiveURL, package: package, origin: .download, cancellation: cancellation, progress: progress
                )
            }
            await remove(archiveURL, package: package)
            return installation
        } catch {
            sink.abandon()
            await remove(archiveURL, package: package)
            throw error
        }
    }

    private func remove(_ url: URL, package: LocalModelPackage) async {
        let operations = operations
        try? await LocalModelBlockingWork.run(name: "Local model download cleanup") {
            try operations.fileSystem.removeTree(url, within: operations.packageDirectory(package))
        }
    }
}

/// Receives body chunks serially on the transport's delegate queue.
private final class DownloadSink: @unchecked Sendable {
    private let writer: LocalModelFileWriter
    private let hasher: LocalModelSHA256Hasher
    private let total: Int64
    private let cancellation: LocalModelCancellation
    private let progress: @Sendable (LocalModelInstallState) -> Void
    private var received: Int64 = 0
    private var published: Int64 = 0

    init(
        writer: LocalModelFileWriter, hasher: LocalModelSHA256Hasher, total: Int64,
        cancellation: LocalModelCancellation, progress: @escaping @Sendable (LocalModelInstallState) -> Void
    ) {
        self.writer = writer
        self.hasher = hasher
        self.total = total
        self.cancellation = cancellation
        self.progress = progress
    }

    func append(_ data: Data) throws {
        try cancellation.check()
        try data.withUnsafeBytes { bytes in
            try hasher.update(bytes)
            try writer.write(bytes)
        }
        received += Int64(data.count)
        if received - published >= max(total / 200, 1 << 20) || received == total {
            published = received
            progress(.downloading(received: received, total: total))
        }
    }

    func finish(expectedSHA256: String) throws {
        try writer.commit()
        guard try hasher.finish() == expectedSHA256 else {
            throw LocalModelStoreError.download(
                "The downloaded archive does not match its pinned SHA-256. Nothing was installed; try again."
            )
        }
    }

    func abandon() {
        writer.discard()
    }
}
