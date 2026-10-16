import CWindowsSupport
import Foundation
import SpeakCore
import SpeakDesktop
import SpeakWindowsPlatform
import XCTest

final class WindowsMigrationPublicationTests: XCTestCase {
    private func fixture() throws -> (source: URL, destination: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let selected = root.appendingPathComponent("Chosen folder", isDirectory: true)
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: false)
        let snapshot = DataMigrationSnapshot(
            manifest: .init(categories: [.settings], scopes: [:]),
            records: [.settings: [.init(
                id: "synthetic", kind: "setting",
                value: AnyCodable(.string(String(repeating: "synthetic", count: 40_000)))
            )]]
        )
        let source = try WindowsMigrationArchive.export(snapshot, stagingRoot: root)
        return (source, selected.appendingPathComponent("Backup-\u{00E9}.zip"))
    }

    func testPrivateCopy_PublishesCompleteIndependentFileAndNeverOverwrites() throws {
        #if os(Windows)
        let fixture = try fixture()
        let expected = try Data(contentsOf: fixture.source)
        XCTAssertGreaterThan(expected.count, 64 * 1024)
        try WindowsMigrationArchive.publish(fixture.source, to: fixture.destination)
        XCTAssertEqual(try Data(contentsOf: fixture.destination), expected)
        XCTAssertEqual(try Data(contentsOf: fixture.source), expected)
        let verified = fixture.source.deletingLastPathComponent().appendingPathComponent("acl-verified.zip")
        try WindowsMigrationArchive.publish(fixture.destination, to: verified)
        XCTAssertEqual(try Data(contentsOf: verified), expected)
        XCTAssertThrowsError(try WindowsMigrationArchive.publish(fixture.source, to: fixture.destination))
        XCTAssertEqual(try Data(contentsOf: fixture.destination), expected)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            atPath: fixture.destination.deletingLastPathComponent().path
        ), [fixture.destination.lastPathComponent])
        #else
        throw XCTSkip("Requires native Windows handle-relative publication.")
        #endif
    }

    func testMidCopyCancellation_RemovesOnlyOwnedPartialAndKeepsSource() throws {
        #if os(Windows)
        let fixture = try fixture()
        let expected = try Data(contentsOf: fixture.source)
        var calls = 0
        var error = [CChar](repeating: 0, count: 1_024)
        let result = withUnsafeMutablePointer(to: &calls) { calls in
            jsti_private_file_publish(fixture.source.path, fixture.destination.path, { pointer in
                guard let count = pointer?.assumingMemoryBound(to: Int.self) else { return 1 }
                count.pointee += 1
                return count.pointee >= 3 ? 1 : 0
            }, calls, &error, error.count)
        }
        XCTAssertEqual(result, 2, String(cString: error))
        XCTAssertEqual(calls, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(
            atPath: fixture.destination.deletingLastPathComponent().path
        ).isEmpty)
        XCTAssertEqual(try Data(contentsOf: fixture.source), expected)
        #else
        throw XCTSkip("Requires native Windows handle-relative publication.")
        #endif
    }

    func testSwiftTaskCancellation_IsVisibleInsideSynchronousNativeCallback() async throws {
        #if os(Windows)
        let fixture = try fixture()
        let task = Task {
            var error = [CChar](repeating: 0, count: 1_024)
            return jsti_private_file_publish(fixture.source.path, fixture.destination.path, { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return Task.isCancelled ? 1 : 0
            }, nil, &error, error.count)
        }
        let result = await task.value
        XCTAssertEqual(result, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.path))
        #else
        throw XCTSkip("Requires native Windows publication callbacks.")
        #endif
    }
}
