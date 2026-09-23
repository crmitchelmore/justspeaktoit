import Foundation
import SpeakCore
@testable import SpeakDesktop
import XCTest

final class LocalModelInstallerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try LocalModelTestFiles.temporaryDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func installer(_ transport: LocalModelDownloadTransport) -> LocalModelInstaller {
        LocalModelInstaller(root: root, digests: TestSHA256.provider, transport: transport)
    }

    private let body = Data((0..<10_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })

    func testTestDigestMatchesKnownVectors() {
        XCTAssertEqual(TestSHA256.hex(Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(
            TestSHA256.hex(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        XCTAssertEqual(
            TestSHA256.hex(Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        )
    }

    func testInstallVerifiesAndWritesTheReceipt() async throws {
        let transport = FakeModelTransport(body: body)
        let installer = installer(transport)
        let item = LocalModelInstaller.Item.fixture(body)
        XCTAssertEqual(installer.state(of: item), .notInstalled)
        var reported: [Int64] = []
        let lock = NSLock()
        let file = try await installer.install(item) { received, _ in lock.withLock { reported.append(received) } }

        XCTAssertEqual(try Data(contentsOf: file), body)
        XCTAssertEqual(installer.state(of: item), .installed)
        XCTAssertEqual(try installer.verifiedFile(for: item), file)
        XCTAssertEqual(reported.last, Int64(body.count))
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.partialURL(for: item).path))
        XCTAssertEqual(transport.requests.map(\.resumeOffset), [0])
        XCTAssertEqual(transport.requests.first?.allowedHosts.contains("huggingface.co"), true)
        try installer.verify(item)
        // A second install is a no-op on a verified file.
        _ = try await installer.install(item)
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testInterruptedDownloadKeepsBytesAndResumesWithARange() async throws {
        let transport = FakeModelTransport(body: body)
        transport.failure = .dropAfter(4_000)
        let installer = installer(transport)
        let item = LocalModelInstaller.Item.fixture(body)

        do {
            _ = try await installer.install(item)
            XCTFail("The dropped connection must fail")
        } catch let error as LocalModelDownloadError {
            XCTAssertEqual(error, .transport("connection reset"))
        }
        guard case .partial(let received, let total) = installer.state(of: item) else {
            return XCTFail("Partial bytes must be kept")
        }
        XCTAssertGreaterThanOrEqual(received, 4_000)
        XCTAssertEqual(total, Int64(body.count))

        transport.failure = .none
        let file = try await installer.install(item)
        XCTAssertEqual(try Data(contentsOf: file), body)
        XCTAssertEqual(transport.requests.last?.resumeOffset, received)
    }

    func testServerThatIgnoresTheRangeRestartsFromTheBeginning() async throws {
        let transport = FakeModelTransport(body: body)
        transport.failure = .dropAfter(3_000)
        let installer = installer(transport)
        let item = LocalModelInstaller.Item.fixture(body)
        _ = try? await installer.install(item)

        transport.failure = .none
        transport.honoursRange = false
        let file = try await installer.install(item)
        XCTAssertEqual(try Data(contentsOf: file), body, "Old partial bytes were truncated, not duplicated")
    }

    func testCancellationKeepsThePartialDownload() async throws {
        let transport = FakeModelTransport(body: body)
        transport.failure = .cancelAfter(2_000)
        let installer = installer(transport)
        let item = LocalModelInstaller.Item.fixture(body)
        do {
            _ = try await installer.install(item)
            XCTFail("Cancellation must propagate")
        } catch is CancellationError {}
        guard case .partial = installer.state(of: item) else { return XCTFail("Cancelled bytes must be resumable") }
    }

    func testDigestMismatchDeletesTheDownloadAndInstallsNothing() async throws {
        let transport = FakeModelTransport(body: body)
        let installer = installer(transport)
        let item = LocalModelInstaller.Item.fixture(body, digest: String(repeating: "0", count: 64))
        do {
            _ = try await installer.install(item)
            XCTFail("A digest mismatch must fail")
        } catch let error as LocalModelInstallError {
            XCTAssertEqual(error, .checksumMismatch)
        }
        XCTAssertEqual(installer.state(of: item), .notInstalled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.fileURL(for: item).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.partialURL(for: item).path))
    }

    func testTamperedInstallationFailsVerificationAndIsRemoved() async throws {
        let installer = installer(FakeModelTransport(body: body))
        let item = LocalModelInstaller.Item.fixture(body)
        let file = try await installer.install(item)
        var tampered = body
        tampered[10] ^= 0xff
        try tampered.write(to: file)
        XCTAssertThrowsError(try installer.verify(item)) {
            XCTAssertEqual($0 as? LocalModelInstallError, .checksumMismatch)
        }
        XCTAssertEqual(installer.state(of: item), .notInstalled)
    }

    func testTruncatedInstallationIsNotReportedAsInstalled() async throws {
        let installer = installer(FakeModelTransport(body: body))
        let item = LocalModelInstaller.Item.fixture(body)
        let file = try await installer.install(item)
        try body.prefix(100).write(to: file)
        XCTAssertNotEqual(installer.state(of: item), .installed)
        XCTAssertThrowsError(try installer.verifiedFile(for: item))
        // Reinstalling replaces the damaged file instead of trusting it.
        let replaced = try await installer.install(item)
        XCTAssertEqual(try Data(contentsOf: replaced), body)
    }

    func testANewPinnedArtefactNeverResumesBytesOfTheOldOne() async throws {
        let transport = FakeModelTransport(body: body)
        transport.failure = .dropAfter(5_000)
        let installer = installer(transport)
        let old = LocalModelInstaller.Item.fixture(body)
        _ = try? await installer.install(old)

        let newBody = Data(body.reversed())
        let replacement = FakeModelTransport(body: newBody)
        let updated = LocalModelInstaller(root: root, digests: TestSHA256.provider, transport: replacement)
        let item = LocalModelInstaller.Item.fixture(newBody)
        let file = try await updated.install(item)
        XCTAssertEqual(try Data(contentsOf: file), newBody)
        XCTAssertEqual(replacement.requests.map(\.resumeOffset), [0])
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: updated.directory(for: item).path)
        XCTAssertEqual(Set(leftovers), [LocalModelInstaller.receiptName, "ggml-fixture.bin"])
    }

    func testRemoveDeletesEverything() async throws {
        let installer = installer(FakeModelTransport(body: body))
        let item = LocalModelInstaller.Item.fixture(body)
        _ = try await installer.install(item)
        try installer.remove(item)
        XCTAssertEqual(installer.state(of: item), .notInstalled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.directory(for: item).path))
        try installer.remove(item)
    }

    func testUnsafeFileNamesAreRefused() async {
        let unsafe = LocalModelInstaller.Item(
            identifier: "x", displayName: "x",
            artifact: LocalModelFileArtifact(
                url: URL(string: "https://huggingface.co/a/b/resolve/c/..")!, filename: "../escape.bin",
                byteCount: 1, sha256: String(repeating: "a", count: 64), license: "MIT", provenance: ""
            )
        )
        do {
            _ = try await installer(FakeModelTransport(body: Data([1]))).install(unsafe)
            XCTFail("Path traversal must be refused")
        } catch let error as LocalModelInstallError {
            XCTAssertEqual(error, .unsafeFileName("../escape.bin"))
        } catch { XCTFail("Unexpected \(error)") }
        XCTAssertTrue(LocalModelInstaller.isSafeFileName("ggml-large-v3-turbo-q5_0.bin"))
        XCTAssertFalse(LocalModelInstaller.isSafeFileName("con.bin "))
    }

    func testDirectoryNamesAreStableAndFilesystemSafe() {
        XCTAssertEqual(LocalModelInstaller.directoryName(for: "local/whisperkit/large-v3-turbo"),
                       "local_whisperkit_large-v3-turbo")
    }

    // MARK: - Transport response classification

    func testRangeResponsesMustContinueExactlyWhereTheFileStops() {
        let request = LocalModelDownloadRequest(
            url: URL(string: "https://huggingface.co/x")!, expectedByteCount: 1_000, allowedHosts: [], resumeOffset: 400
        )
        typealias Transport = LocalModelURLSessionTransport
        XCTAssertEqual(
            try Transport.classify(status: 206, contentRange: "bytes 400-999/1000", declaredLength: 600,
                                   request: request).get(),
            .resumed(offset: 400)
        )
        XCTAssertEqual(
            try Transport.classify(status: 206, contentRange: "bytes 400-999/*", declaredLength: 600,
                                   request: request).get(),
            .resumed(offset: 400)
        )
        for range in ["bytes 0-999/1000", "bytes 400-998/1000", "bytes 400-999/2000", "bytes */1000", nil] {
            if case .success = Transport.classify(status: 206, contentRange: range, declaredLength: 600,
                                                  request: request) {
                XCTFail("Accepted \(String(describing: range))")
            }
        }
        XCTAssertEqual(
            try Transport.classify(status: 200, contentRange: nil, declaredLength: 1_000, request: request).get(),
            .fromBeginning
        )
        XCTAssertEqual(
            try Transport.classify(status: 200, contentRange: nil, declaredLength: -1, request: request).get(),
            .fromBeginning
        )
        guard case .failure(.lengthMismatch) = Transport.classify(
            status: 200, contentRange: nil, declaredLength: 999, request: request
        ) else { return XCTFail("A short full response must be refused") }
        guard case .failure(.httpStatus(404)) = Transport.classify(
            status: 404, contentRange: nil, declaredLength: -1, request: request
        ) else { return XCTFail("HTTP errors must be reported") }
        guard case .failure(.rangeRefused) = Transport.classify(
            status: 416, contentRange: nil, declaredLength: -1, request: request
        ) else { return XCTFail("416 must restart") }
    }

    func testTransportRefusesInsecureAndUnexpectedHosts() async {
        let transport = LocalModelURLSessionTransport()
        for url in ["http://huggingface.co/x", "https://example.com/x"] {
            let request = LocalModelDownloadRequest(
                url: URL(string: url)!, expectedByteCount: 1, allowedHosts: ["huggingface.co"]
            )
            do {
                try await transport.download(request, start: { _ in }, sink: { _ in })
                XCTFail("\(url) must be refused before any request")
            } catch let error as LocalModelDownloadError {
                XCTAssertEqual(error, .insecureURL)
            } catch { XCTFail("Unexpected \(error)") }
        }
    }
}
