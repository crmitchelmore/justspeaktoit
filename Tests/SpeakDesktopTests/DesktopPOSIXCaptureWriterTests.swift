import Foundation
import SpeakCore
import SpeakDesktop
import XCTest

#if os(Linux) && canImport(Glibc)
final class DesktopPOSIXCaptureWriterTests: XCTestCase {
    func testRealHeldPCMAtBothRates() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for rate in [16_000, 24_000] {
            let owned = try DesktopOwnedCaptureFile.create(in: root)
            let file = try PCMRecordingFile(ownedFile: owned, sampleRate: rate)
            let pcm = Data(repeating: 21, count: rate / 5)
            try file.append(pcm)
            XCTAssertEqual(try file.finish(), 0.1, accuracy: 1e-9)
            XCTAssertEqual(try Data(contentsOf: owned.url), PCMWaveWriter.wavData(pcm: pcm, sampleRate: rate))
        }
    }

    func testConcurrentDirectoryCollisionHasExactlyOneOwner() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directoryID = UUID()
        let successes = await withTaskGroup(of: Int.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    do {
                        let file = try DesktopOwnedCaptureFile.create(in: root, directoryID: directoryID)
                        try file.discard()
                        return 1
                    } catch { return 0 }
                }
            }
            var count = 0
            for await value in group { count += value }
            return count
        }
        XCTAssertEqual(successes, 1)
    }

    func testRootReplacementCannotRedirectWritesOrCleanup() throws {
        let root = try makeRoot()
        let moved = root.appendingPathExtension("moved")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: moved)
        }
        let owned = try DesktopOwnedCaptureFile.create(in: root)
        let relative = owned.url.pathComponents.suffix(2)
        try FileManager.default.moveItem(at: root, to: moved)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let replacement = relative.reduce(root) { $0.appendingPathComponent($1) }
        try FileManager.default.createDirectory(at: replacement.deletingLastPathComponent(),
                                                withIntermediateDirectories: false)
        let sentinel = Data("unrelated replacement".utf8)
        try sentinel.write(to: replacement)
        try owned.write(Data([1, 2]))
        XCTAssertThrowsError(try owned.retain())
        try owned.discard()
        XCTAssertEqual(try Data(contentsOf: replacement), sentinel)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: relative.reduce(moved) { $0.appendingPathComponent($1) }.path
        ))
    }

    func testPrivateSubdirectoryReplacementCannotRedirectCleanup() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let owned = try DesktopOwnedCaptureFile.create(in: root)
        let folder = owned.url.deletingLastPathComponent()
        let moved = root.appendingPathComponent("moved", isDirectory: true)
        try FileManager.default.moveItem(at: folder, to: moved)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let sentinel = Data("not owned".utf8)
        try sentinel.write(to: owned.url)
        XCTAssertThrowsError(try owned.synchronize())
        try owned.discard()
        XCTAssertEqual(try Data(contentsOf: owned.url), sentinel)
        XCTAssertFalse(FileManager.default.fileExists(atPath: moved.appendingPathComponent(
            owned.url.lastPathComponent
        ).path))
    }

    func testLeafReplacementIsKeptAndCleanupReportsFailure() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let owned = try DesktopOwnedCaptureFile.create(in: root)
        let original = owned.url.appendingPathExtension("original")
        try FileManager.default.moveItem(at: owned.url, to: original)
        let sentinel = Data("foreign file".utf8)
        try sentinel.write(to: owned.url)
        try owned.write(Data([1, 2]))
        XCTAssertEqual(try Data(contentsOf: original), Data([1, 2]))
        XCTAssertThrowsError(try owned.discard())
        XCTAssertEqual(try Data(contentsOf: owned.url), sentinel)
    }

    func testSymlinkAndWritableAncestryAreRejectedWithoutFollowingThem() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try DesktopOwnedCaptureFile.create(in: link))
        let belowLink = link.appendingPathComponent("below")
        try FileManager.default.createDirectory(at: target.appendingPathComponent("below"),
                                                withIntermediateDirectories: false)
        XCTAssertThrowsError(try DesktopOwnedCaptureFile.create(in: belowLink))
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: target.path)
        XCTAssertThrowsError(try DesktopOwnedCaptureFile.create(in: target))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.path).allSatisfy { $0 == "below" })
    }

    func testMalformedRootAndExistingLinkedUUIDDirectoryCannotGrantOwnership() throws {
        XCTAssertThrowsError(try DesktopOwnedCaptureFile.create(in: XCTUnwrap(URL(string: "https://example.test"))))
        XCTAssertThrowsError(try DesktopOwnedCaptureFile.create(in: XCTUnwrap(URL(string: "file://foreign.test/"))))
        XCTAssertThrowsError(try DesktopOwnedCaptureFile.create(in: XCTUnwrap(URL(string: "file:///?unexpected=1"))))
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let foreign = root.appendingPathComponent("foreign")
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: false)
        let sentinel = foreign.appendingPathComponent("unrelated.wav")
        try Data([7, 8]).write(to: sentinel)
        let directoryID = UUID()
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent(directoryID.uuidString), withDestinationURL: foreign
        )
        XCTAssertThrowsError(try DesktopOwnedCaptureFile.create(in: root, directoryID: directoryID))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data([7, 8]))
    }

    func testCancellationOnlyRemovesItsUnpublishedFile() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let unrelated = root.appendingPathComponent("unrelated.wav")
        let sentinel = Data([3, 4])
        try sentinel.write(to: unrelated)
        var checks = 0
        XCTAssertThrowsError(try DesktopOwnedCaptureFile.create(in: root, checkCancellation: {
            checks += 1
            if checks == 2 { throw CancellationError() }
        }))
        XCTAssertEqual(try Data(contentsOf: unrelated), sentinel)
        let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0 != unrelated }
        XCTAssertEqual(folders.count, 1)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: XCTUnwrap(folders.first).path).isEmpty)
    }

    func testRootChangedAfterPCMAdmissionFailsFinishButRetainsOriginalForRecovery() throws {
        let root = try makeRoot()
        let moved = root.appendingPathExtension("moved")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: moved)
        }
        let owned = try DesktopOwnedCaptureFile.create(in: root)
        let file = try PCMRecordingFile(ownedFile: owned)
        let pcm = Data([1, 0, 2, 0])
        try file.append(pcm)
        try FileManager.default.moveItem(at: root, to: moved)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        XCTAssertThrowsError(try file.finish())
        let original = owned.url.pathComponents.suffix(2).reduce(moved) { $0.appendingPathComponent($1) }
        XCTAssertEqual(try Data(contentsOf: original), PCMWaveWriter.wavData(pcm: pcm, sampleRate: 16_000))
        XCTAssertThrowsError(try owned.discard())
    }

    private func makeRoot() throws -> URL {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("owned-capture-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return root
    }
}
#endif
