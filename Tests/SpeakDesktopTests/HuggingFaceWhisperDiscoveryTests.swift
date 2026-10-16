import Foundation
import XCTest
import SpeakCore
import SpeakDesktop

final class HuggingFaceWhisperDiscoveryTests: XCTestCase {
    func testReadsHeadThenImmutableCommitWithExactDigestAndSize() async throws {
        let data = try WhisperImportFixtures.metadata()
        let transport = FixtureWhisperMetadata([data, data])
        let imported = try await HuggingFaceWhisperDiscovery(transport: transport)
            .discover(repository: "fixture/whisper", filename: "ggml-tiny.bin")
        XCTAssertEqual(imported.sha256, WhisperImportFixtures.digest)
        XCTAssertEqual(imported.byteCount, 48)
        XCTAssertEqual(imported.revision, WhisperImportFixtures.revision)
        XCTAssertEqual(transport.urls.map(\.absoluteString), [
            "https://huggingface.co/api/models/fixture/whisper/revision/main?blobs=true",
            "https://huggingface.co/api/models/fixture/whisper/revision/\(WhisperImportFixtures.revision)?blobs=true"
        ])
        XCTAssertEqual(imported.artifact.url.scheme, "https")
        XCTAssertFalse(imported.artifact.url.absoluteString.contains("/main/"))
    }

    func testRevisionOrArtifactDriftIsRejected() async throws {
        let first = try WhisperImportFixtures.metadata()
        for second in [
            try WhisperImportFixtures.metadata(revision: String(repeating: "c", count: 40)),
            try WhisperImportFixtures.metadata(digest: String(repeating: "c", count: 64)),
            try WhisperImportFixtures.metadata(size: 49)
        ] {
            do {
                _ = try await HuggingFaceWhisperDiscovery(transport: FixtureWhisperMetadata([first, second]))
                    .discover(repository: "fixture/whisper", filename: "ggml-tiny.bin")
                XCTFail("Drifting metadata acquired import authority")
            } catch {
                XCTAssertEqual(error as? HuggingFaceWhisperError, .revisionChanged)
            }
        }
    }

    func testMissingDigestDuplicateFileAndAbsentFileAreRejected() async throws {
        for body in [
            try WhisperImportFixtures.metadata(hasLFS: false),
            try WhisperImportFixtures.metadata(duplicate: true),
            try WhisperImportFixtures.metadata(filename: "ggml-small.bin"),
            try WhisperImportFixtures.metadata(digest: "unverified")
        ] {
            let transport = FixtureWhisperMetadata([body])
            do {
                _ = try await HuggingFaceWhisperDiscovery(transport: transport)
                    .discover(repository: "fixture/whisper", filename: "ggml-tiny.bin")
                XCTFail("Unverified file imported")
            } catch {
                XCTAssertEqual(error as? HuggingFaceWhisperError, .invalidMetadata)
            }
            XCTAssertEqual(transport.urls.count, 1)
        }
    }

    func testUnsafeInputIsRejectedBeforeAnyTransportCall() async {
        let transport = FixtureWhisperMetadata([])
        do {
            _ = try await HuggingFaceWhisperDiscovery(transport: transport)
                .discover(repository: "fixture/repo%2fother", filename: "ggml-tiny.bin")
            XCTFail("Unsafe repository reached discovery")
        } catch {
            XCTAssertEqual(error as? HuggingFaceWhisperError, .invalidRepository)
        }
        XCTAssertTrue(transport.urls.isEmpty)
    }

    func testOversizeAndMalformedMetadataFailClosed() async {
        for body in [Data(repeating: 32, count: HuggingFaceWhisperDiscovery.maximumMetadataBytes + 1),
                     Data("{not json".utf8)] {
            let transport = FixtureWhisperMetadata([body])
            do {
                _ = try await HuggingFaceWhisperDiscovery(transport: transport)
                    .discover(repository: "fixture/whisper", filename: "ggml-tiny.bin")
                XCTFail("Invalid metadata imported")
            } catch {
                XCTAssertEqual(transport.urls.count, 1)
            }
        }
    }

    func testCancellationDoesNotStartThePinnedRead() async throws {
        let transport = FixtureWhisperMetadata([try WhisperImportFixtures.metadata()], delay: true)
        let task = Task {
            try await HuggingFaceWhisperDiscovery(transport: transport)
                .discover(repository: "fixture/whisper", filename: "ggml-tiny.bin")
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled discovery returned an import")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertLessThanOrEqual(transport.urls.count, 1)
    }
}
