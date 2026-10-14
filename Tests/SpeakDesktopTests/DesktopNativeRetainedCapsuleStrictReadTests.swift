import Foundation
import SpeakCore
import SpeakDesktop
import XCTest

final class DesktopNativeRetainedReadTests: XCTestCase {
    private struct Fixture {
        let directory: URL
        let file: URL
        let bytes: Data
    }

    private func fixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            DesktopNativeRetainedCapsule.directoryPrefix + UUID().uuidString, isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let archive = try DesktopNativeConfigurationArchiveCodec.project(.capture(
            ["postProcessing.customPrompt": AnyCodable(.string("original"))], platform: .linux,
            selectedFields: ["postProcessing.customPrompt"]
        ))
        let bytes = try DesktopNativeConfigurationArchiveCodec.encode(archive)
        let file = directory.appendingPathComponent(DesktopNativeRetainedCapsule.filename)
        try bytes.write(to: file)
        return Fixture(directory: directory, file: file, bytes: bytes)
    }

    func testReplacementAtCanonicalPreopenCheck_IsRejectedWithoutTouchingEitherFile() throws {
        let source = try fixture()
        let saved = source.directory.appendingPathComponent("original.json")
        var checks = 0
        XCTAssertThrowsError(try DesktopNativeRetainedCapsule.read(from: source.directory, checkCancellation: {
            checks += 1
            // For the selected one-directory reader contract, check four immediately precedes opening.
            if checks == 4 {
                try FileManager.default.moveItem(at: source.file, to: saved)
                try source.bytes.write(to: source.file)
            }
        })) {
            guard case DesktopOwnedAppDataFileReadError.changedSource = $0 else {
                return XCTFail("Expected a changed-source read error, got \($0).")
            }
        }
        XCTAssertGreaterThanOrEqual(checks, 4)
        XCTAssertEqual(try Data(contentsOf: saved), source.bytes)
        XCTAssertEqual(try Data(contentsOf: source.file), source.bytes)
    }

    func testReplacementAfterReadBeforeCodecInspection_IsRejectedByStrictRevalidation() throws {
        let source = try fixture()
        var checks = 0
        XCTAssertThrowsError(try DesktopNativeRetainedCapsule.read(from: source.directory, checkCancellation: {
            checks += 1
            // The selected one-directory strict read finishes nine checks before codec inspection begins.
            if checks == 10 { try source.bytes.write(to: source.file, options: .atomic) }
        })) {
            guard case DesktopOwnedAppDataFileReadError.changedSource = $0 else {
                return XCTFail("Expected strict receipt revalidation to refuse replacement, got \($0).")
            }
        }
        XCTAssertGreaterThanOrEqual(checks, 10)
        XCTAssertEqual(try Data(contentsOf: source.file), source.bytes)
    }

    func testSymlinkedRecord_IsRejectedWithoutReadingOrDeletingTarget() throws {
        let source = try fixture()
        let target = source.directory.appendingPathComponent("target.json")
        try FileManager.default.moveItem(at: source.file, to: target)
        try FileManager.default.createSymbolicLink(at: source.file, withDestinationURL: target)
        XCTAssertThrowsError(try DesktopNativeRetainedCapsule.read(from: source.directory)) {
            guard case DesktopOwnedAppDataFileReadError.unsafeFile = $0 else {
                return XCTFail("Expected unsafe file, got \($0).")
            }
        }
        XCTAssertEqual(try Data(contentsOf: target), source.bytes)
    }

    func testHardLinkedRecord_IsRejectedAndBothNamesRemain() throws {
        let source = try fixture()
        let other = source.directory.appendingPathComponent("other.json")
        try FileManager.default.linkItem(at: source.file, to: other)
        XCTAssertThrowsError(try DesktopNativeRetainedCapsule.read(from: source.directory)) {
            guard case DesktopOwnedAppDataFileReadError.unsafeFile = $0 else {
                return XCTFail("Expected unsafe hard link, got \($0).")
            }
        }
        XCTAssertEqual(try Data(contentsOf: source.file), source.bytes)
        XCTAssertEqual(try Data(contentsOf: other), source.bytes)
    }

    func testLinkedCapsuleDirectory_IsRejectedAndOriginalRemains() throws {
        let source = try fixture()
        let link = source.directory.appendingPathComponent(
            DesktopNativeRetainedCapsule.directoryPrefix + UUID().uuidString, isDirectory: true
        )
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source.directory)
        XCTAssertThrowsError(try DesktopNativeRetainedCapsule.read(from: link)) {
            guard case DesktopOwnedAppDataFileReadError.unsafeDirectory = $0 else {
                return XCTFail("Expected unsafe directory, got \($0).")
            }
        }
        XCTAssertEqual(try Data(contentsOf: source.file), source.bytes)
    }

    func testSparseOversizedRecord_IsRejectedBeforeAllocatingItsDeclaredSize() throws {
        let source = try fixture()
        let handle = try FileHandle(forWritingTo: source.file)
        try handle.truncate(atOffset: DesktopNativeConfigurationArchiveCodec.maximumEncodedBytes + 1)
        try handle.close()
        XCTAssertThrowsError(try DesktopNativeRetainedCapsule.read(from: source.directory)) {
            guard case DesktopOwnedAppDataFileReadError.exceedsByteBudget = $0 else {
                return XCTFail("Expected canonical reader budget failure, got \($0).")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.file.path))
    }

    func testAbsentRecord_IsAnErrorNotAnEmptyArchiveOrSettingsClear() throws {
        let source = try fixture()
        try FileManager.default.removeItem(at: source.file)
        XCTAssertThrowsError(try DesktopNativeRetainedCapsule.read(from: source.directory)) {
            XCTAssertEqual(($0 as? CocoaError)?.code, .fileReadNoSuchFile)
        }
    }

    func testCancellationBeforeAndAfterStrictRead_PreservesTypedCauseAndSourceBytes() throws {
        let source = try fixture()
        XCTAssertThrowsError(try DesktopNativeRetainedCapsule.read(
            from: source.directory, checkCancellation: { throw CancellationError() }
        )) { XCTAssertTrue($0 is CancellationError) }
        var checks = 0
        XCTAssertThrowsError(try DesktopNativeRetainedCapsule.read(from: source.directory, checkCancellation: {
            checks += 1
            if checks == 10 { throw CancellationError() }
        })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(checks, 10)
        XCTAssertEqual(try Data(contentsOf: source.file), source.bytes)
    }
}
