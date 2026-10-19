import CRecordingFileSupport
import Foundation
import SpeakDesktop
import XCTest

final class DesktopFileReplacementTests: XCTestCase {
    func testReplace_OverwritesWholeUnicodeDestinationAndConsumesOnlySiblingStaging() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent("staged-\u{1F600}.partial")
        let destination = root.appendingPathComponent("chosen-\u{00E9}.mp3")
        try Data("prior complete synthetic bytes".utf8).write(to: destination)
        for bytes in [Data([0xFF, 0xF3, 0x90, 0, 1, 2]), Data("second complete synthetic file".utf8)] {
            try bytes.write(to: staging, options: .withoutOverwriting)
            try DesktopFilePublication.replace(staging: staging, destination: destination)
            XCTAssertEqual(try Data(contentsOf: destination), bytes)
            XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path),
                       [destination.lastPathComponent])
    }

    func testReplace_NewDestinationIsAnIndependentRegularFile() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent("owned.partial")
        let destination = root.appendingPathComponent("new.wav")
        let bytes = Data("synthetic whole file".utf8)
        try bytes.write(to: staging)
        try DesktopFilePublication.replace(staging: staging, destination: destination)
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeRegular)
        XCTAssertEqual((attributes[.referenceCount] as? NSNumber)?.intValue, 1)
    }

    func testReplace_NativeFailurePreservesStagingAndExistingDirectoryContents() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent("owned.partial")
        let destination = root.appendingPathComponent("blocked.m4a")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let sentinel = destination.appendingPathComponent("prior.bin")
        let bytes = Data("synthetic complete bytes".utf8)
        try bytes.write(to: staging)
        try bytes.write(to: sentinel)
        XCTAssertThrowsError(try DesktopFilePublication.replace(staging: staging, destination: destination))
        XCTAssertEqual(try Data(contentsOf: staging), bytes)
        XCTAssertEqual(try Data(contentsOf: sentinel), bytes)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)),
                       ["owned.partial", "blocked.m4a"])
    }

    func testReplace_MissingStagingReportsNativeErrorAndPreservesExistingDestination() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent("missing.partial")
        let destination = root.appendingPathComponent("prior.mp3")
        let prior = Data("synthetic prior complete bytes".utf8)
        try prior.write(to: destination)
        XCTAssertThrowsError(try DesktopFilePublication.replace(staging: staging, destination: destination)) {
            let error = $0 as NSError
            #if os(Windows)
            XCTAssertEqual(error.domain, "JSTIFileReplacementWindows")
            #else
            XCTAssertEqual(error.domain, NSPOSIXErrorDomain)
            #endif
            XCTAssertEqual(error.code, 2) // ERROR_FILE_NOT_FOUND / ENOENT, captured before native cleanup.
        }
        XCTAssertEqual(try Data(contentsOf: destination), prior)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["prior.mp3"])
    }

    func testReplace_IdenticalNonSiblingAndInvalidURLsRefuseWithoutMutation() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent("owned.partial")
        let bytes = Data("synthetic untouched staging".utf8)
        try bytes.write(to: staging)
        let other = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        let invalid = [
            staging, other.appendingPathComponent("chosen.wav"),
            try XCTUnwrap(URL(string: "https://example.invalid/chosen.wav")),
            try XCTUnwrap(URL(string: "file://remote.invalid/chosen.wav")),
            try XCTUnwrap(URL(string: "file:///invalid%00.wav")),
            root.appendingPathComponent("directory", isDirectory: true)
        ]
        for destination in invalid {
            XCTAssertThrowsError(try DesktopFilePublication.replace(staging: staging, destination: destination))
            XCTAssertEqual(try Data(contentsOf: staging), bytes)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: other.path), [])
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)),
                       ["owned.partial", "other"])
    }

    func testReplace_CancellationBeforeCommitPreservesBothCompleteFiles() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent("owned.partial")
        let destination = root.appendingPathComponent("prior.wav")
        let prior = Data("synthetic prior complete bytes".utf8)
        let next = Data("synthetic replacement complete bytes".utf8)
        try prior.write(to: destination)
        try next.write(to: staging)
        let work = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try DesktopFilePublication.replace(staging: staging, destination: destination)
        }
        do { try await work.value; XCTFail("Cancelled replacement committed.") } catch is CancellationError {}
        XCTAssertEqual(try Data(contentsOf: staging), next)
        XCTAssertEqual(try Data(contentsOf: destination), prior)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)),
                       ["owned.partial", "prior.wav"])
    }

    func testVoiceWrite_DelegatesOverwriteAndCleansFailedSiblingWithoutChangingPriorBytes() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("chosen.wav")
        let prior = Data("synthetic prior bytes".utf8)
        let next = Data("synthetic whole replacement".utf8)
        try prior.write(to: destination)
        try DesktopVoiceExportPublication.write(next, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), next)
        let blocked = root.appendingPathComponent("blocked.mp3")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: false)
        let sentinel = blocked.appendingPathComponent("kept")
        try prior.write(to: sentinel)
        XCTAssertThrowsError(try DesktopVoiceExportPublication.write(next, to: blocked))
        XCTAssertEqual(try Data(contentsOf: destination), next)
        XCTAssertEqual(try Data(contentsOf: sentinel), prior)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)),
                       ["chosen.wav", "blocked.mp3"])
    }

    func testNativeABI_DifferentParentsRefuseWithoutConsumingEitherFile() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent("owned.partial")
        let other = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        let destination = other.appendingPathComponent("chosen.wav")
        let bytes = Data("synthetic untouched bytes".utf8)
        try bytes.write(to: staging)
        try bytes.write(to: destination)
        let status = staging.withUnsafeFileSystemRepresentation { source in
            destination.withUnsafeFileSystemRepresentation { target in jsti_file_replace(source, target) }
        }
        XCTAssertNotEqual(status, 0)
        XCTAssertEqual(try Data(contentsOf: staging), bytes)
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
    }

    func testWindowsNativeABI_InvalidUTF8AndEncodedSurrogateRefuseBeforeRename() throws {
        #if os(Windows)
        let invalidSequences: [[UInt8]] = [[0xC3], [0xED, 0xA0, 0x80]]
        for invalid in invalidSequences {
            let source = (Array("C:\\synthetic\\invalid-".utf8) + invalid + [0]).map { CChar(bitPattern: $0) }
            let status = source.withUnsafeBufferPointer { source in
                "C:\\synthetic\\chosen.wav".withCString { target in
                    jsti_file_replace(source.baseAddress, target)
                }
            }
            XCTAssertEqual(status, 1113) // ERROR_NO_UNICODE_TRANSLATION, not a later filesystem error.
        }
        #else
        throw XCTSkip("Requires the Windows UTF-8 to UTF-16 filesystem adapter.")
        #endif
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "replacement-\(UUID())-\u{00E9}-\u{1F600}"
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
}
