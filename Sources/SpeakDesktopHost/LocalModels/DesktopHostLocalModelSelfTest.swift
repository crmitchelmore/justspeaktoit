import Foundation
import SpeakCore
import SpeakDesktop

/// The synthetic model both hosts' `--self-test` downloads, interrupts,
/// resumes, verifies, tampers with and removes through the real installer.
package struct DesktopHostLocalModelSelfTest {
    /// Bytes the transport drops the first download after.
    package static let interruptedAfter = 120_000

    package let body: Data
    package let item: LocalModelInstaller.Item
    package let transport: Transport

    /// Pins the synthetic model to its digest under `digests`.
    package init(digests: LocalModelDigestProvider) throws {
        body = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        item = LocalModelInstaller.Item(
            identifier: "local/whisperkit/tiny", displayName: "Self-test model",
            artifact: LocalModelFileArtifact(
                url: URL(string: "https://huggingface.co/self-test/resolve/0/ggml-self-test.bin")!,
                filename: "ggml-self-test.bin", byteCount: Int64(body.count), sha256: try digests.sha256(of: body),
                license: "MIT", provenance: "synthetic"
            )
        )
        transport = Transport(body: body, dropAfter: Self.interruptedAfter)
    }

    /// Serves `body` like a range-capable HTTP server, optionally dropping the
    /// connection after a byte count.
    package final class Transport: LocalModelDownloadTransport, @unchecked Sendable {
        let body: Data
        private let lock = NSLock()
        private var drop: Int?
        private var requested: [Int64] = []

        package var dropAfter: Int? {
            get { lock.withLock { drop } }
            set { lock.withLock { drop = newValue } }
        }

        /// The resume offset of every request, in order.
        package var offsets: [Int64] { lock.withLock { requested } }

        init(body: Data, dropAfter: Int?) {
            self.body = body
            self.drop = dropAfter
        }

        package func download(
            _ request: LocalModelDownloadRequest, start: @escaping @Sendable (LocalModelDownloadStart) throws -> Void,
            sink: @escaping @Sendable (Data) throws -> Void
        ) async throws {
            let limit = lock.withLock { () -> Int? in
                requested.append(request.resumeOffset)
                return drop
            }
            var position = Int(request.resumeOffset)
            try start(position > 0 ? .resumed(offset: Int64(position)) : .fromBeginning)
            var sent = 0
            while position < body.count {
                if let limit, sent >= limit { throw LocalModelDownloadError.transport("synthetic reset") }
                let end = min(position + 16_384, body.count)
                try sink(body.subdata(in: position..<end))
                sent += end - position
                position = end
            }
        }
    }
}
