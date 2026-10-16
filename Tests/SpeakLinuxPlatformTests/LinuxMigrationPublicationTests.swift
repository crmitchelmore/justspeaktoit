import CLinuxSupport
import Foundation
import SpeakCore
import SpeakDesktop
import SpeakLinuxPlatform
import XCTest

final class LinuxMigrationPublicationTests: XCTestCase {
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
        let source = try LinuxMigrationArchive.export(snapshot, stagingRoot: root)
        return (source, selected.appendingPathComponent("Backup-\u{00E9}.zip"))
    }

    func testPrivateCopy_PublishesCompleteIndependentFileWithoutOverwriting() throws {
        let fixture = try fixture()
        let expected = try Data(contentsOf: fixture.source)
        XCTAssertGreaterThan(expected.count, 64 * 1024)
        try LinuxMigrationArchive.publish(fixture.source, to: fixture.destination)
        XCTAssertEqual(try Data(contentsOf: fixture.destination), expected)
        XCTAssertEqual(try Data(contentsOf: fixture.source), expected)
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.destination.path)
        XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, NSNumber(value: 0o600))
        XCTAssertThrowsError(try LinuxMigrationArchive.publish(fixture.source, to: fixture.destination))
        XCTAssertEqual(try Data(contentsOf: fixture.destination), expected)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            atPath: fixture.destination.deletingLastPathComponent().path
        ), [fixture.destination.lastPathComponent])
    }

    func testMidCopyCancellation_RemovesOwnedPartialWithoutPublishing() throws {
        let fixture = try fixture()
        let expected = try Data(contentsOf: fixture.source)
        var calls = 0
        var error = [CChar](repeating: 0, count: 1_024)
        let result = withUnsafeMutablePointer(to: &calls) { calls in
            fixture.source.path.withCString { source in
                fixture.destination.path.withCString { destination in
                    jsti_private_file_publish(source, destination, { pointer in
                        guard let count = pointer?.assumingMemoryBound(to: Int.self) else { return 1 }
                        count.pointee += 1
                        return count.pointee >= 3 ? 1 : 0
                    }, calls, &error, error.count)
                }
            }
        }
        XCTAssertEqual(result, 2, String(cString: error))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(
            atPath: fixture.destination.deletingLastPathComponent().path
        ).isEmpty)
        XCTAssertEqual(try Data(contentsOf: fixture.source), expected)
    }

    func testExistingDestinationLink_IsNotReplacedOrFollowed() throws {
        let fixture = try fixture()
        let expected = try Data(contentsOf: fixture.source)
        try FileManager.default.createSymbolicLink(at: fixture.destination, withDestinationURL: fixture.source)
        XCTAssertThrowsError(try LinuxMigrationArchive.publish(fixture.source, to: fixture.destination))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.destination.path),
                       fixture.source.path)
        XCTAssertEqual(try Data(contentsOf: fixture.source), expected)
    }

    func testSwiftTaskCancellation_IsVisibleInsideSynchronousNativeCallback() async throws {
        let fixture = try fixture()
        let task = Task {
            var error = [CChar](repeating: 0, count: 1_024)
            return fixture.source.path.withCString { source in
                fixture.destination.path.withCString { destination in
                    jsti_private_file_publish(source, destination, { _ in
                        withUnsafeCurrentTask { $0?.cancel() }
                        return Task.isCancelled ? 1 : 0
                    }, nil, &error, error.count)
                }
            }
        }
        let result = await task.value
        XCTAssertEqual(result, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.path))
    }

    func testSourceMutationDuringCopy_RejectsInconsistentSnapshot() throws {
        let fixture = try fixture()
        var change = PublicationSourceChange(source: fixture.source)
        var error = [CChar](repeating: 0, count: 1_024)
        let result = withUnsafeMutablePointer(to: &change) { change in
            fixture.source.path.withCString { source in
                fixture.destination.path.withCString { destination in
                    jsti_private_file_publish(source, destination, { pointer in
                        guard let state = pointer?.assumingMemoryBound(to: PublicationSourceChange.self) else {
                            return 1
                        }
                        state.pointee.calls += 1
                        if state.pointee.calls == 3 {
                            do {
                                let handle = try FileHandle(forWritingTo: state.pointee.source)
                                try handle.write(contentsOf: Data([0]))
                                try handle.close()
                            } catch {
                                state.pointee.failure = error
                                return 1
                            }
                        }
                        return 0
                    }, change, &error, error.count)
                }
            }
        }
        XCTAssertNil(change.failure)
        XCTAssertGreaterThanOrEqual(change.calls, 3)
        XCTAssertEqual(result, -1)
        XCTAssertTrue(String(cString: error).contains("changed"), String(cString: error))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(
            atPath: fixture.destination.deletingLastPathComponent().path
        ).isEmpty)
    }
}

private struct PublicationSourceChange {
    let source: URL
    var calls = 0
    var failure: Error?
}
