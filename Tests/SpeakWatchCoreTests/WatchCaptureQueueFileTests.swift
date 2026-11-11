import Foundation
import SpeakWatchCore
import XCTest

/// A damaged capture queue must stay distinguishable from an empty one, and
/// must never be overwritten or deleted.
@MainActor
final class WatchCaptureQueueFileTests: XCTestCase {
    private func makeQueueURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("captures.json")
    }

    private let capture = WatchCapture(
        id: UUID(), createdAt: Date(timeIntervalSince1970: 1_700_000_000), duration: 12, status: .delivered
    )

    func testMissingQueue_opensEmptyAndSaves() throws {
        let url = try makeQueueURL()
        let file = WatchCaptureQueueFile(fileURL: url)

        XCTAssertEqual(file.read(), .absent)
        XCTAssertEqual(file.open(), [])
        XCTAssertNil(file.issue)
        try file.save([self.capture])
        XCTAssertEqual(WatchCaptureQueueFile(fileURL: url).read(), .loaded([self.capture]))
    }

    func testCorruptQueue_isSetAsideWithItsBytes_andANewQueueStarts() throws {
        let url = try makeQueueURL()
        let damaged = Data("[{\"id\": \"not-a-uuid\"".utf8)
        try damaged.write(to: url)
        let file = WatchCaptureQueueFile(fileURL: url)

        guard case .corrupt = file.read() else { return XCTFail("A damaged queue must not read as absent") }
        XCTAssertEqual(file.open(), [])
        guard case .setAside(let preserved) = file.issue else {
            return XCTFail("Expected the queue to be set aside, got \(String(describing: file.issue))")
        }
        XCTAssertEqual(try Data(contentsOf: preserved), damaged)
        XCTAssertEqual(preserved.deletingLastPathComponent(), url.deletingLastPathComponent())
        XCTAssertFalse(file.issue?.blocksSaving ?? true)

        try file.save([self.capture])
        XCTAssertEqual(file.read(), .loaded([self.capture]))
        XCTAssertEqual(try Data(contentsOf: preserved), damaged)
        file.dismissNotice()
        XCTAssertNil(file.issue)
    }

    func testUnreadableQueue_blocksSavingUntilItCanBeRead() throws {
        let url = try makeQueueURL()
        // A directory where the file should be cannot be read as data, which
        // stands in for a queue data protection keeps locked.
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        let file = WatchCaptureQueueFile(fileURL: url)

        XCTAssertEqual(file.open(), [])
        XCTAssertEqual(file.issue, .unreadable)
        XCTAssertThrowsError(try file.save([self.capture])) {
            XCTAssertEqual($0 as? WatchCaptureQueueFileError, .damagedQueue)
        }
        XCTAssertEqual(file.issue, .unreadable)
        file.dismissNotice()
        XCTAssertEqual(file.issue, .unreadable, "Only a set-aside notice can be dismissed")
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue, "The unreadable queue is left in place")

        // Once readable again, a reload restores the queue and saving resumes.
        try FileManager.default.removeItem(at: url)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([self.capture]).write(to: url)
        XCTAssertEqual(file.open(), [self.capture])
        XCTAssertNil(file.issue)
        try file.save([])
        XCTAssertEqual(file.read(), .loaded([]))
    }

    func testFailedWrite_isReportedAndClearedByTheNextSave() throws {
        let url = try makeQueueURL()
        // A file where the queue's directory should be makes the write fail.
        let blocked = url.deletingLastPathComponent().appendingPathComponent("blocked")
        try Data().write(to: blocked)
        let unwritable = WatchCaptureQueueFile(fileURL: blocked.appendingPathComponent("captures.json"))
        XCTAssertEqual(unwritable.open(), [])

        XCTAssertThrowsError(try unwritable.save([self.capture]))
        XCTAssertEqual(unwritable.issue, .saveFailed)
        XCTAssertFalse(unwritable.issue?.blocksSaving ?? true)

        try FileManager.default.removeItem(at: blocked)
        try unwritable.save([self.capture])
        XCTAssertNil(unwritable.issue)
    }

    func testQueueBackedByTheFile_keepsItsStateWhenTheWriteIsRefused() throws {
        let url = try makeQueueURL()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        let file = WatchCaptureQueueFile(fileURL: url)
        let transport = IdleTransport()
        let queue = WatchCaptureQueue(
            captures: file.open(),
            transport: transport,
            audioURL: { URL(fileURLWithPath: "/captures/\($0.uuidString).m4a") },
            persist: { (try? file.save($0)) != nil }
        )

        XCTAssertFalse(queue.enqueue(id: UUID(), createdAt: Date(), duration: 3))
        XCTAssertEqual(queue.captures, [])
        XCTAssertEqual(file.issue, .unreadable)
    }

    private final class IdleTransport: WatchCaptureTransport {
        var isActivated: Bool { false }
        func hasOutstandingTransfer(for id: UUID) -> Bool { false }
        func transferFile(_ url: URL, envelope: WatchCaptureEnvelope) {}
    }
}
