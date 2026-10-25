#if os(iOS)
import XCTest
@testable import SpeakiOSLib

@MainActor
final class TranscriptReadyNotificationLedgerTests: XCTestCase {
    func testClaimsPersistAcrossRestartAndOnlyExplicitDeletionRetiresThem() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("claims.json")
        let first = UUID()
        let second = UUID()
        let ledger = TranscriptReadyNotificationLedger(url: url)
        XCTAssertTrue(try ledger.claim(first, at: Date()))
        XCTAssertTrue(try ledger.claim(second, at: Date()))
        let restarted = TranscriptReadyNotificationLedger(url: url)
        XCTAssertFalse(try restarted.claim(first, at: Date()))
        try restarted.forget([first])
        XCTAssertTrue(try restarted.claim(first, at: Date()))
        XCTAssertFalse(try restarted.claim(second, at: Date()))
    }

    func testLedgerWriter_RequestsAtomicProtectedStorageForClaimsAndDeletion() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("claims.json")
        var options: [Data.WritingOptions] = []
        let ledger = TranscriptReadyNotificationLedger(url: url, write: { data, destination, requested in
            options.append(requested)
            try data.write(to: destination, options: requested)
        })
        let identifier = UUID()
        XCTAssertTrue(try ledger.claim(identifier, at: Date()))
        try ledger.forget([identifier])
        XCTAssertEqual(options.count, 2)
        XCTAssertTrue(options.allSatisfy { $0.contains(.atomic) })
        XCTAssertTrue(options.allSatisfy { $0.contains(.completeFileProtectionUntilFirstUserAuthentication) })
        // Simulator does not expose effective physical data-protection attributes.
        // Requested options are proven here; locked-device protection remains acceptance work.
    }

    func testUnreadableAndFutureVersionLedger_NeverBecomeEmptyOrWriteNewClaims() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var writes = 0
        let unreadable = TranscriptReadyNotificationLedger(url: url, read: { _ in
            throw CocoaError(.fileReadNoPermission)
        }, write: { _, _, _ in writes += 1 })
        XCTAssertThrowsError(try unreadable.claim(UUID(), at: Date()))
        XCTAssertThrowsError(try unreadable.forget([UUID()]))
        XCTAssertEqual(writes, 0)
        let future = TranscriptReadyNotificationLedger(url: url, read: { _ in
            Data(#"{"version":99,"claims":[]}"#.utf8)
        }, write: { _, _, _ in writes += 1 })
        XCTAssertThrowsError(try future.claim(UUID(), at: Date()))
        XCTAssertEqual(writes, 0)
    }

    func testCorruptAndUnwritableLedgerFailClosedWithoutReplacingExistingBytes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("claims.json")
        let corrupt = Data("not-json".utf8)
        try corrupt.write(to: url)
        XCTAssertThrowsError(try TranscriptReadyNotificationLedger(url: url).claim(UUID(), at: Date()))
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
        try FileManager.default.removeItem(at: url)
        let unwritable = TranscriptReadyNotificationLedger(url: url, write: { _, _, _ in
            throw CocoaError(.fileWriteNoPermission)
        })
        XCTAssertThrowsError(try unwritable.claim(UUID(), at: Date()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
#endif
