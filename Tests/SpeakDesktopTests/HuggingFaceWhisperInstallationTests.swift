import Foundation
import XCTest
import SpeakCore
@testable import SpeakDesktop

final class HuggingFaceWhisperInstallationTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws { directory = try LocalModelTestFiles.temporaryDirectory() }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func installer(_ transport: FakeModelTransport) -> LocalModelInstaller {
        LocalModelInstaller(
            root: directory, digests: TestSHA256.provider, transport: transport,
            validateArtifact: { item, file in
                try WhisperGGMLImportValidation.validate(file, filename: item.artifact.filename)
            }
        )
    }

    func testOriginalInitializerReferenceDefaultAndTrailingClosureRemainCompatible() async throws {
        let body = WhisperImportFixtures.header()
        let item = LocalModelInstaller.Item(try WhisperImportFixtures.model(body: body).model)
        let make = LocalModelInstaller.init(root:digests:transport:prepareDirectory:)
        let prepare: @Sendable (URL) throws -> Void = { url in
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data([1]).write(to: url.deletingLastPathComponent().appendingPathComponent("prepared"))
        }
        let referenceRoot = directory.appendingPathComponent("reference")
        let defaultRoot = directory.appendingPathComponent("default")
        let trailingRoot = directory.appendingPathComponent("trailing")
        let referenced = make(referenceRoot, TestSHA256.provider, FakeModelTransport(body: body), prepare)
        let defaulted = LocalModelInstaller(
            root: defaultRoot, digests: TestSHA256.provider, transport: FakeModelTransport(body: body)
        )
        let trailing = LocalModelInstaller(
            root: trailingRoot, digests: TestSHA256.provider, transport: FakeModelTransport(body: body)
        ) { url in
            try prepare(url)
        }
        for installing in [referenced, defaulted, trailing] {
            let file = try await installing.install(item)
            XCTAssertEqual(try Data(contentsOf: file), body)
            XCTAssertEqual(try installing.verifiedFile(for: item), file)
            XCTAssertEqual(installing.state(of: item), .installed)
        }
        for root in [referenceRoot, trailingRoot] {
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("prepared")), Data([1]))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: defaultRoot.appendingPathComponent("prepared").path))
    }

    func testVerifiedGGMLInstallsAndRestartsWithSameIdentityAndReceipt() async throws {
        let body = WhisperImportFixtures.header()
        let model = try WhisperImportFixtures.model(body: body)
        let transport = FakeModelTransport(body: body)
        let item = LocalModelInstaller.Item(model.model)
        let first = installer(transport)
        let file = try await first.install(item)
        XCTAssertEqual(try Data(contentsOf: file), body)
        XCTAssertEqual(first.state(of: item), .installed)
        let restarted = installer(FakeModelTransport(body: Data()))
        XCTAssertEqual(try restarted.verifiedFile(for: item), file)
        try restarted.verify(item)
        XCTAssertEqual(transport.requests.first?.expectedByteCount, Int64(body.count))
        XCTAssertEqual(transport.requests.first?.url, model.artifact.url)
        XCTAssertTrue(transport.requests.first?.allows(host: "cdn.hf.co") == true)
        XCTAssertFalse(transport.requests.first?.allows(host: "hf.co.attacker.test") == true)
    }

    func testCorrectDigestCannotTurnCoreMLOrGGUFBytesIntoGGML() async throws {
        for magic in [Data("GGUF".utf8), Data("core".utf8), Data("ONNX".utf8)] {
            var body = WhisperImportFixtures.header()
            body.replaceSubrange(0..<4, with: magic)
            let model = try WhisperImportFixtures.model(body: body)
            let item = LocalModelInstaller.Item(model.model)
            let installing = installer(FakeModelTransport(body: body))
            do {
                _ = try await installing.install(item)
                XCTFail("A filename and matching SHA-256 bypassed format validation")
            } catch {
                XCTAssertEqual(error as? HuggingFaceWhisperError, .incompatibleHeader)
            }
            XCTAssertNotEqual(installing.state(of: item), .installed)
            XCTAssertFalse(FileManager.default.fileExists(atPath: installing.fileURL(for: item).path))
        }
    }

    func testArchitectureQuantizationAndTruncatedHeadersAreRejected() {
        XCTAssertThrowsError(try WhisperGGMLImportValidation.validate(
            header: WhisperImportFixtures.header(), filename: "ggml-base.bin"
        ))
        XCTAssertThrowsError(try WhisperGGMLImportValidation.validate(
            header: WhisperImportFixtures.header(type: 8), filename: "ggml-tiny.bin"
        ))
        XCTAssertThrowsError(try WhisperGGMLImportValidation.validate(
            header: WhisperImportFixtures.header().prefix(47), filename: "ggml-tiny.bin"
        ))
        XCTAssertNoThrow(try WhisperGGMLImportValidation.validate(
            header: WhisperImportFixtures.header(type: 2_008), filename: "ggml-tiny-q5_0.bin"
        ))
    }

    func testCancellationAndFailureRetainOnlyResumablePinnedBytes() async throws {
        let body = WhisperImportFixtures.header()
        let model = try WhisperImportFixtures.model(body: body)
        let item = LocalModelInstaller.Item(model.model)
        let transport = FakeModelTransport(body: body)
        transport.failure = .cancelAfter(14)
        let installing = installer(transport)
        do {
            _ = try await installing.install(item)
            XCTFail("Cancelled download installed")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(installing.state(of: item), .partial(received: 14, total: 48))
        transport.failure = .dropAfter(7)
        do {
            _ = try await installing.install(item)
            XCTFail("Failed transport installed")
        } catch {
            XCTAssertEqual(installing.state(of: item), .partial(received: 21, total: 48))
        }
        transport.failure = .none
        _ = try await installing.install(item)
        XCTAssertEqual(transport.requests.map(\.resumeOffset), [0, 14, 21])
        XCTAssertEqual(installing.state(of: item), .installed)
    }

    func testDigestMismatchCannotCreateAnInstalledReceipt() async throws {
        let model = try WhisperImportFixtures.model()
        var corrupt = WhisperImportFixtures.header()
        corrupt[47] ^= 1
        let installing = installer(FakeModelTransport(body: corrupt))
        let item = LocalModelInstaller.Item(model.model)
        do {
            _ = try await installing.install(item)
            XCTFail("Corrupt weights installed")
        } catch {
            XCTAssertEqual(error as? LocalModelInstallError, .checksumMismatch)
        }
        XCTAssertEqual(installing.state(of: item), .notInstalled)
    }

    func testRemovingOneImportLeavesAnotherImportAndItsMetadataAlone() async throws {
        let body = WhisperImportFixtures.header()
        let first = try WhisperImportFixtures.model(body: body)
        var secondBody = body
        secondBody.append(0)
        let second = try WhisperImportFixtures.model(body: secondBody)
        let store = HuggingFaceWhisperStore(directory: directory) {
            try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true)
        }
        try store.save([first, second])
        let one = installer(FakeModelTransport(body: body))
        let two = installer(FakeModelTransport(body: secondBody))
        _ = try await one.install(.init(first.model))
        _ = try await two.install(.init(second.model))
        try one.remove(.init(first.model))
        XCTAssertEqual(one.state(of: .init(first.model)), .notInstalled)
        XCTAssertEqual(two.state(of: .init(second.model)), .installed)
        XCTAssertEqual(try store.load(), [first, second])
    }
}
