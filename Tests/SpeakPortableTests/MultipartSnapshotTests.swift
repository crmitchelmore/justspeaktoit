import Foundation
import XCTest
@testable import SpeakCore

/// The one multipart byte copy shared by the generic batch job, Cartesia and
/// xAI. Golden bodies pin every byte the three callers write, so the shared
/// helper cannot drift a header, separator or trailer for any of them.
final class MultipartSnapshotTests: XCTestCase {
    private var scratch: URL!
    /// Where the snapshot tests stage bodies, so cleanup is observable without
    /// racing other processes' temporary files.
    private var staging: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("multipart-tests-\(UUID().uuidString)", isDirectory: true)
        staging = scratch.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    func testGenericJob_writesTheGoldenBodyAndKeepsTheRecording() throws {
        let source = try recording(named: "take.wav", bytes: Data([0, 1, 2, 0xFF]))
        let file = try BatchTranscriptionJob.writeMultipart(
            fields: [(name: "model", value: "m1"), (name: "language", value: "en")],
            file: .init(field: "file", filename: "take.wav", mimeType: "audio/wav", source: source),
            boundary: "B"
        )
        defer { BatchTranscriptionJob.discard(file) }
        let expected = Data(("--B\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nm1\r\n"
            + "--B\r\nContent-Disposition: form-data; name=\"language\"\r\n\r\nen\r\n"
            + "--B\r\nContent-Disposition: form-data; name=\"file\"; filename=\"take.wav\"\r\n"
            + "Content-Type: audio/wav\r\n\r\n").utf8) + Data([0, 1, 2, 0xFF]) + Data("\r\n--B--\r\n".utf8)
        XCTAssertEqual(try Data(contentsOf: file), expected)
        XCTAssertEqual(file.lastPathComponent, "upload.multipart")
        XCTAssertEqual(try Data(contentsOf: source), Data([0, 1, 2, 0xFF]))
    }

    func testCartesia_writesTheGoldenBody() throws {
        let source = try recording(named: "take.m4a", bytes: Data("AUDIO".utf8))
        let upload = try CartesiaBatchClient.makeUpload(url: source, apiKey: "fixture", language: "fr-CA")
        defer { BatchTranscriptionJob.discard(upload.file) }
        let boundary = try Self.boundary(of: upload.request)
        let expected = "--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nink-whisper\r\n"
            + "--\(boundary)\r\nContent-Disposition: form-data; name=\"language\"\r\n\r\nfr\r\n"
            + "--\(boundary)\r\nContent-Disposition: form-data; name=\"timestamp_granularities[]\"\r\n\r\nword\r\n"
            + "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"recording.m4a\"\r\n"
            + "Content-Type: audio/mp4\r\n\r\nAUDIO\r\n--\(boundary)--\r\n"
        XCTAssertEqual(try Data(contentsOf: upload.file), Data(expected.utf8))
        XCTAssertNil(upload.request.httpBody)
    }

    func testXAI_writesTheGoldenBody() throws {
        let source = try recording(named: "take.wav", bytes: Data("AUDIO".utf8))
        let upload = try XAIBatchTranscriptionClient.makeUpload(
            url: source, apiKey: "fixture", language: "en-GB", keywords: ["Ada"]
        )
        defer { BatchTranscriptionJob.discard(upload.file) }
        let boundary = try Self.boundary(of: upload.request)
        let expected = "--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n"
            + "grok-voice-transcribe-2.0\r\n"
            + "--\(boundary)\r\nContent-Disposition: form-data; name=\"language\"\r\n\r\nen\r\n"
            + "--\(boundary)\r\nContent-Disposition: form-data; name=\"format\"\r\n\r\ntrue\r\n"
            + "--\(boundary)\r\nContent-Disposition: form-data; name=\"keyterm\"\r\n\r\nAda\r\n"
            + "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"recording.wav\"\r\n"
            + "Content-Type: audio/wav\r\n\r\nAUDIO\r\n--\(boundary)--\r\n"
        XCTAssertEqual(try Data(contentsOf: upload.file), Data(expected.utf8))
        XCTAssertNil(upload.request.httpBody)
    }

    /// A recording larger than several chunks is copied exactly, in bounded chunks.
    func testSnapshot_copiesInBoundedChunks() throws {
        let bytes = Data((0..<(BatchTranscriptionJob.multipartCopyChunkBytes * 3 + 17)).map { UInt8($0 % 251) })
        let source = try recording(named: "long.wav", bytes: bytes)
        var chunkSizes: [Int] = []
        let file = try BatchTranscriptionJob.writeMultipartSnapshot(
            header: Data("H".utf8), source: source, boundary: "B", temporaryRoot: staging
        ) { output, chunk in
            chunkSizes.append(chunk.count)
            try output.write(contentsOf: chunk)
        }
        defer { BatchTranscriptionJob.discard(file) }
        XCTAssertEqual(chunkSizes.count, 4)
        XCTAssertTrue(chunkSizes.allSatisfy { $0 <= BatchTranscriptionJob.multipartCopyChunkBytes })
        XCTAssertEqual(try Data(contentsOf: file), Data("H".utf8) + bytes + Data("\r\n--B--\r\n".utf8))
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertEqual(file.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL,
                       staging.standardizedFileURL)
        #if !os(Windows)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        #endif
    }

    func testSnapshot_injectedWriteFailureRemovesTheSnapshotAndKeepsTheRecording() throws {
        let bytes = Data(repeating: 7, count: BatchTranscriptionJob.multipartCopyChunkBytes * 2)
        let source = try recording(named: "fail.wav", bytes: bytes)
        var writes = 0
        XCTAssertThrowsError(
            try BatchTranscriptionJob.writeMultipartSnapshot(
                header: Data("H".utf8), source: source, boundary: "B", temporaryRoot: staging
            ) { output, chunk in
                writes += 1
                if writes == 2 { throw CocoaError(.fileWriteOutOfSpace) }
                try output.write(contentsOf: chunk)
            }
        ) { error in
            XCTAssertEqual((error as? CocoaError)?.code, .fileWriteOutOfSpace)
        }
        XCTAssertEqual(writes, 2)
        XCTAssertEqual(try stagedEntries(), [])
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    /// Cancelling the owning task mid-copy stops before the next chunk, removes
    /// the partial snapshot and leaves the recording intact. The test thread is
    /// not a cooperative-pool thread, so blocking it cannot starve the copy.
    func testSnapshot_cancellationDuringCopyRemovesTheSnapshotAndKeepsTheRecording() throws {
        let bytes = Data(repeating: 3, count: BatchTranscriptionJob.multipartCopyChunkBytes * 3)
        let source = try recording(named: "cancel.wav", bytes: bytes)
        let staging = staging!
        let started = DispatchSemaphore(value: 0)
        let proceed = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let outcome = CopyOutcome()
        let task = Task.detached {
            var writes = 0
            outcome.result = Result {
                try BatchTranscriptionJob.writeMultipartSnapshot(
                    header: Data("H".utf8), source: source, boundary: "B", temporaryRoot: staging
                ) { output, chunk in
                    writes += 1
                    try output.write(contentsOf: chunk)
                    if writes == 1 {
                        started.signal()
                        proceed.wait()
                    }
                }
            }
            outcome.writes = writes
            finished.signal()
        }
        XCTAssertEqual(started.wait(timeout: .now() + 10), .success)
        task.cancel()
        proceed.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(outcome.writes, 1)
        switch outcome.result {
        case .failure(let error): XCTAssertTrue(error is CancellationError, "\(error)")
        case .success(let file):
            BatchTranscriptionJob.discard(file)
            XCTFail("A cancelled copy must not produce a snapshot")
        case nil: XCTFail("The copy did not finish")
        }
        XCTAssertEqual(try stagedEntries(), [])
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    func testSharedAudioContentTypes_matchTheModulateAndSonioxTable() {
        let cases = [
            "aac": "audio/aac", "aiff": "audio/aiff", "aif": "audio/aiff", "flac": "audio/flac",
            "mov": "video/quicktime", "mp3": "audio/mpeg", "mp4": "audio/mp4", "m4a": "audio/mp4",
            "ogg": "audio/ogg", "opus": "audio/opus", "wav": "audio/wav", "webm": "audio/webm",
            "WAV": "audio/wav", "caf": "application/octet-stream", "": "application/octet-stream"
        ]
        for (pathExtension, expected) in cases {
            let url = URL(fileURLWithPath: "/recording").appendingPathExtension(pathExtension)
            XCTAssertEqual(SharedMultipartUploadStaging.audioContentType(for: url), expected, pathExtension)
        }
    }

    private final class CopyOutcome: @unchecked Sendable {
        var result: Result<URL, Error>?
        var writes = 0
    }

    private func recording(named name: String, bytes: Data) throws -> URL {
        let url = scratch.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    private func stagedEntries() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: staging.path)
    }

    private static func boundary(of request: URLRequest) throws -> String {
        let contentType = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))
        let prefix = "multipart/form-data; boundary="
        XCTAssertTrue(contentType.hasPrefix(prefix))
        return String(contentType.dropFirst(prefix.count))
    }
}
