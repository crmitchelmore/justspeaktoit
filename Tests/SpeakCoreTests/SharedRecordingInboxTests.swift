import XCTest
@testable import SpeakCore

/// The hand-off between the Share extension and the app (issue #1020). It is
/// two processes writing to one directory, either of which can be killed
/// mid-write, so the rules below are the ones that keep a half-finished import
/// inert instead of dangerous.
final class SharedRecordingInboxTests: XCTestCase {
    private var root = URL(fileURLWithPath: NSTemporaryDirectory())
    private var inbox = SharedRecordingInbox(root: URL(fileURLWithPath: NSTemporaryDirectory()))

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SharedRecordingInboxTests-\(UUID().uuidString)")
        inbox = SharedRecordingInbox(root: root)
        try inbox.prepare()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    func testAnEmptyInboxHasNothingPending() {
        XCTAssertTrue(inbox.pending().isEmpty)
    }

    func testACommittedItemIsPendingAndRoundTrips() throws {
        let item = try stage(filename: "Walk in the park.m4a", bytes: 32)
        let pending = inbox.pending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first, item)
        XCTAssertEqual(pending.first?.originalFilename, "Walk in the park.m4a")
    }

    func testItemsComeBackOldestFirstSoImportsRunInTheOrderTheyWereShared() throws {
        let older = try stage(filename: "first.m4a", bytes: 8, receivedAt: Date(timeIntervalSince1970: 10))
        let newer = try stage(filename: "second.m4a", bytes: 8, receivedAt: Date(timeIntervalSince1970: 20))
        XCTAssertEqual(inbox.pending().map(\.id), [older.id, newer.id])
    }

    func testAManifestWithNoAudioIsDroppedRatherThanRetriedForever() throws {
        // The extension was killed between writing the copy and committing, or
        // the copy was cleared: either way there is nothing to transcribe and
        // the app must not keep finding it on every foreground.
        let item = try stage(filename: "interrupted.m4a", bytes: 8)
        try FileManager.default.removeItem(
            at: inbox.stagedURL(id: item.id, fileExtension: item.fileExtension)
        )
        XCTAssertTrue(inbox.pending().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: inbox.manifestURL(id: item.id).path))
    }

    func testAnAudioCopyWithNoManifestIsInvisibleUntilItIsCommitted() throws {
        // The manifest is written last on purpose: an item the app can see is
        // an item whose bytes are all present.
        let id = UUID()
        try Data(count: 16).write(to: inbox.stagedURL(id: id, fileExtension: "m4a"))
        XCTAssertTrue(inbox.pending().isEmpty)
    }

    func testRemovingAnItemClearsBothTheCopyAndItsManifest() throws {
        let item = try stage(filename: "done.m4a", bytes: 8)
        inbox.remove(item)
        XCTAssertTrue(inbox.pending().isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: inbox.stagedURL(id: item.id, fileExtension: item.fileExtension).path
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: inbox.manifestURL(id: item.id).path))
    }

    func testTheStagedPathIgnoresTheUsersFilenameEntirely() {
        // A shared item can be named anything at all. The copy is named after
        // the item's UUID so a name carrying separators cannot escape the
        // inbox directory or collide with another import.
        let id = UUID()
        let url = inbox.stagedURL(id: id, fileExtension: "m4a")
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, root.standardizedFileURL)
        XCTAssertEqual(url.lastPathComponent, "\(id.uuidString).m4a")
    }

    func testPreparingTwiceIsHarmless() throws {
        try inbox.prepare()
        try inbox.prepare()
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
    }

    // MARK: - Helpers

    @discardableResult
    private func stage(
        filename: String,
        bytes: Int,
        receivedAt: Date = Date()
    ) throws -> SharedRecordingInboxItem {
        let item = SharedRecordingInboxItem(
            originalFilename: filename,
            fileExtension: URL(fileURLWithPath: filename).pathExtension,
            byteCount: bytes,
            receivedAt: receivedAt
        )
        try Data(count: bytes).write(
            to: inbox.stagedURL(id: item.id, fileExtension: item.fileExtension)
        )
        try inbox.commit(item)
        return item
    }
}

/// A recoverable failure must not throw the user's only staged copy away, and
/// nothing may sit in the queue for ever.
final class SharedRecordingAttemptTests: XCTestCase {
    private var root = URL(fileURLWithPath: NSTemporaryDirectory())

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeStagedItem(in inbox: SharedRecordingInbox) throws -> SharedRecordingInboxItem {
        try inbox.prepare()
        let item = SharedRecordingInboxItem(
            originalFilename: "memo.m4a",
            fileExtension: "m4a",
            byteCount: 4
        )
        try Data([1, 2, 3, 4]).write(to: inbox.stagedURL(id: item.id, fileExtension: "m4a"))
        try inbox.commit(item)
        return item
    }

    func testANewItemStartsWithNoAttempts() throws {
        let inbox = SharedRecordingInbox(root: root)
        let item = try makeStagedItem(in: inbox)
        XCTAssertEqual(item.attemptCount, 0)
        XCTAssertEqual(inbox.pending().first?.attemptCount, 0)
    }

    func testAnAttemptIsPersistedAndTheAudioIsKept() throws {
        let inbox = SharedRecordingInbox(root: root)
        let item = try makeStagedItem(in: inbox)
        let updated = inbox.registerAttempt(item)
        XCTAssertEqual(updated.attemptCount, 1)
        XCTAssertEqual(inbox.pending().first?.attemptCount, 1)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: inbox.stagedURL(id: item.id, fileExtension: "m4a").path
            ),
            "the staged audio must survive a counted retry"
        )
    }

    func testAttemptsAccumulateUpToTheLimit() throws {
        let inbox = SharedRecordingInbox(root: root)
        var item = try makeStagedItem(in: inbox)
        for expected in 1...SharedRecordingInbox.maximumAttempts {
            item = inbox.registerAttempt(item)
            XCTAssertEqual(item.attemptCount, expected)
        }
        XCTAssertGreaterThanOrEqual(item.attemptCount, SharedRecordingInbox.maximumAttempts)
    }

    /// Manifests the extension wrote before attempts were counted still decode.
    func testAManifestWithoutAnAttemptCountDecodesAsZero() throws {
        let inbox = SharedRecordingInbox(root: root)
        try inbox.prepare()
        let id = UUID()
        let json = """
        {"id":"\(id.uuidString)","originalFilename":"old.m4a","fileExtension":"m4a",\
        "byteCount":4,"receivedAt":1000}
        """
        try Data([1, 2, 3, 4]).write(to: inbox.stagedURL(id: id, fileExtension: "m4a"))
        try Data(json.utf8).write(to: inbox.manifestURL(id: id))
        XCTAssertEqual(inbox.pending().first?.attemptCount, 0)
    }
}
