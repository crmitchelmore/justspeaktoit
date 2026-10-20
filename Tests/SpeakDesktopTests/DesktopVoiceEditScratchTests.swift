import Foundation
import SpeakDesktop
import XCTest
#if os(Windows)
import WinSDK
#endif

// WinSDK also exports a C `UUID` (GUID), which makes bare `UUID()` ambiguous on Windows.
private typealias UUID = Foundation.UUID

final class DesktopVoiceEditScratchTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("voice-edit-scratch-\(UUID())")
        #if os(Windows)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #else
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        #endif
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testExclusiveOwner_IsRetainedAcrossRunCleanupUntilReleased() throws {
        var owner: DesktopVoiceEditScratch? = try DesktopVoiceEditScratch(preparedDirectory: directory)
        let id = UUID()
        let run = try XCTUnwrap(owner).createRun(id)
        try Data("private instruction".utf8).write(to: run.appendingPathComponent("instruction.wav"))
        XCTAssertThrowsError(try DesktopVoiceEditScratch(preparedDirectory: directory))
        XCTAssertTrue(FileManager.default.fileExists(atPath: run.appendingPathComponent("instruction.wav").path))
        try XCTUnwrap(owner).removeRun(id)
        XCTAssertThrowsError(try DesktopVoiceEditScratch(preparedDirectory: directory))
        owner = nil
        let reopened = try DesktopVoiceEditScratch(preparedDirectory: directory)
        XCTAssertEqual(reopened.directory, directory)
    }

    func testAbandonedAudioAndEmptyRuns_AreRemovedOnlyAfterOwnerRelease() throws {
        let audio = UUID()
        let empty = UUID()
        do {
            let owner = try DesktopVoiceEditScratch(preparedDirectory: directory)
            let run = try owner.createRun(audio)
            try Data("private instruction".utf8).write(to: run.appendingPathComponent("instruction.wav"))
            _ = try owner.createRun(empty)
        }
        let reopened = try DesktopVoiceEditScratch(preparedDirectory: directory)
        XCTAssertEqual(reopened.directory, directory)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testUnknownNamesAndExtraEntries_AreNeverRecursivelyDeleted() throws {
        let unknown = directory.appendingPathComponent("not-owned")
        try FileManager.default.createDirectory(at: unknown, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: unknown.appendingPathComponent("instruction.wav"))
        let owner = try DesktopVoiceEditScratch(preparedDirectory: directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unknown.path))
        let id = UUID()
        let run = try owner.createRun(id)
        let audio = run.appendingPathComponent("instruction.wav")
        try Data("private instruction".utf8).write(to: audio)
        try Data("unrecognized".utf8).write(to: run.appendingPathComponent("other"))
        XCTAssertThrowsError(try owner.removeRun(id))
        XCTAssertEqual(try Data(contentsOf: audio), Data("private instruction".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: run.appendingPathComponent("other").path))
    }

    func testExistingRun_IsNotReusedOrTruncated() throws {
        let owner = try DesktopVoiceEditScratch(preparedDirectory: directory)
        let id = UUID()
        let run = try owner.createRun(id)
        let audio = run.appendingPathComponent("instruction.wav")
        try Data("keep".utf8).write(to: audio)
        XCTAssertThrowsError(try owner.createRun(id))
        XCTAssertEqual(try Data(contentsOf: audio), Data("keep".utf8))
    }

    func testRefusedStartupScan_ReleasesItsLeaseAndPreservesUnknownData() throws {
        let id = UUID()
        let run: URL
        do {
            let owner = try DesktopVoiceEditScratch(preparedDirectory: directory)
            run = try owner.createRun(id)
            try Data("private instruction".utf8).write(to: run.appendingPathComponent("instruction.wav"))
            try Data("keep".utf8).write(to: run.appendingPathComponent("other"))
        }
        XCTAssertThrowsError(try DesktopVoiceEditScratch(preparedDirectory: directory))
        XCTAssertEqual(try Data(contentsOf: run.appendingPathComponent("other")), Data("keep".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: run.appendingPathComponent("instruction.wav").path))
        try FileManager.default.removeItem(at: run.appendingPathComponent("other"))
        let reopened = try DesktopVoiceEditScratch(preparedDirectory: directory)
        XCTAssertEqual(reopened.directory, directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: run.path))
    }

    #if !os(Windows)
    func testDirectoryAndAudioSymlinks_AreRefusedWithoutTouchingTheirTargets() throws {
        let owner = try DesktopVoiceEditScratch(preparedDirectory: directory)
        let outside = directory.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let outsideAudio = outside.appendingPathComponent("instruction.wav")
        try Data("keep".utf8).write(to: outsideAudio)
        let linkID = UUID()
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent(linkID.uuidString), withDestinationURL: outside
        )
        XCTAssertThrowsError(try owner.removeRun(linkID))
        let id = UUID()
        let run = try owner.createRun(id)
        try FileManager.default.createSymbolicLink(
            at: run.appendingPathComponent("instruction.wav"), withDestinationURL: outsideAudio
        )
        XCTAssertThrowsError(try owner.removeRun(id))
        XCTAssertEqual(try Data(contentsOf: outsideAudio), Data("keep".utf8))
    }

    #endif

    func testHardLinkedAudio_IsRefusedAndBothNamesRemain() throws {
        let owner = try DesktopVoiceEditScratch(preparedDirectory: directory)
        let id = UUID()
        let run = try owner.createRun(id)
        let audio = run.appendingPathComponent("instruction.wav")
        // Outside the owned root: on Windows the owner denies write sharing on it, so no new
        // name can be added there. The temporary directory keeps both names on one volume.
        let other = FileManager.default.temporaryDirectory.appendingPathComponent("voice-edit-link-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: other) }
        try Data("keep".utf8).write(to: audio)
        #if os(Windows)
        let source = try XCTUnwrap(fileSystemPath(audio))
        let target = try XCTUnwrap(fileSystemPath(other))
        let sourceWide = Array(source.utf16) + [0]
        let targetWide = Array(target.utf16) + [0]
        let created = targetWide.withUnsafeBufferPointer { targetBuffer in
            sourceWide.withUnsafeBufferPointer { CreateHardLinkW(targetBuffer.baseAddress, $0.baseAddress, nil) }
        }
        guard created else { throw NSError(domain: "Win32", code: Int(GetLastError())) }
        #else
        try FileManager.default.linkItem(at: audio, to: other)
        #endif
        XCTAssertThrowsError(try owner.removeRun(id))
        XCTAssertEqual(try Data(contentsOf: audio), Data("keep".utf8))
        XCTAssertEqual(try Data(contentsOf: other), Data("keep".utf8))
    }

    #if os(Windows)
    private func fileSystemPath(_ url: URL) -> String? {
        url.withUnsafeFileSystemRepresentation { (path: UnsafePointer<CChar>?) -> String? in
            path.map { String(cString: $0) }
        }
    }
    #endif

    #if !os(Windows)
    func testPublicDirectory_IsNotAcceptedAsPrivateScratch() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        XCTAssertThrowsError(try DesktopVoiceEditScratch(preparedDirectory: directory))
    }
    #endif
}
