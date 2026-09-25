import Foundation
import SpeakCore
@testable import SpeakDesktop
import XCTest

/// The speech runtime reads a model file only when it loads it, so a host
/// rehashes the file before any load and only then.
final class LocalModelLoadVerificationTests: XCTestCase {
    private var root: URL!
    private let body = Data((0..<10_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })

    override func setUpWithError() throws {
        root = try LocalModelTestFiles.temporaryDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var item: LocalModelInstaller.Item { .fixture(body) }

    private func installed() async throws -> (installer: LocalModelInstaller, file: URL) {
        let installer = LocalModelInstaller(
            root: root, digests: TestSHA256.provider, transport: FakeModelTransport(body: body)
        )
        return (installer, try await installer.install(item))
    }

    func testASameSizeReplacementPassesTheReceiptButNotTheLoadCheck() async throws {
        let (installer, file) = try await installed()
        XCTAssertEqual(try installer.verifyForLoading(item), LocalModelFileIdentity(fileAt: file))
        var tampered = body
        tampered[10] ^= 0xff
        try tampered.write(to: file)
        XCTAssertEqual(try installer.verifiedFile(for: item), file, "The receipt and size cannot see the change")
        XCTAssertThrowsError(try installer.verifyForLoading(item)) {
            XCTAssertEqual($0 as? LocalModelInstallError, .checksumMismatch)
        }
        XCTAssertEqual(installer.state(of: item), .notInstalled, "A mismatch deletes the model")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testOnlyTheLastVerifiedUnchangedFileSkipsHashing() async throws {
        let (installer, file) = try await installed()
        var verification = LocalModelLoadVerification()
        let identity = try installer.installedFile(for: item).identity
        #if os(Linux) || os(macOS)
        XCTAssertNotNil(identity.fileNumber, "POSIX reports the inode")
        XCTAssertNotNil(identity.modified)
        #endif
        XCTAssertFalse(verification.isCurrent(file, identity: identity), "Nothing is verified in a new process")
        verification.record(file, identity: identity)
        XCTAssertTrue(verification.isCurrent(file, identity: identity))

        // A replacement is a new file, even with the same bytes.
        try body.write(to: file, options: .atomic)
        let replaced = try XCTUnwrap(LocalModelFileIdentity(fileAt: file))
        if identity.fileNumber != nil { XCTAssertNotEqual(replaced.fileNumber, identity.fileNumber) }
        verification.record(file, identity: replaced)
        // Writing in place moves the modification time.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 3_600)], ofItemAtPath: file.path
        )
        let written = try XCTUnwrap(LocalModelFileIdentity(fileAt: file))
        XCTAssertFalse(verification.isCurrent(file, identity: written))

        // Once another model is verified, the runtime may load this one again.
        verification.record(file, identity: written)
        let other = root.appendingPathComponent("other.bin")
        try body.write(to: other)
        let otherIdentity = try XCTUnwrap(LocalModelFileIdentity(fileAt: other))
        verification.record(other, identity: otherIdentity)
        XCTAssertFalse(verification.isCurrent(file, identity: written))
        verification.forget(file)
        XCTAssertTrue(verification.isCurrent(other, identity: otherIdentity), "Forgetting another file keeps this one")
        verification.forget(other)
        XCTAssertFalse(verification.isCurrent(other, identity: otherIdentity))
    }

    func testIdentityNeedsARegularFile() {
        XCTAssertNil(LocalModelFileIdentity(fileAt: root))
        XCTAssertNil(LocalModelFileIdentity(fileAt: root.appendingPathComponent("missing.bin")))
    }
}
