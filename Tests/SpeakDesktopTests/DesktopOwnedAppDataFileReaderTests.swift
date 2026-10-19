import Foundation
import XCTest
@testable import SpeakDesktop

final class DesktopOwnedAppDataFileReaderTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }

    func testRead_RetainsExactBytesWithoutCodecInterpretationOrReordering() throws {
        let root = try directory()
        let raw = Data(" [ {\"id\":\"second\",\"future\":[null,true]}, {\"id\":\"first\"} ]\r\n".utf8)
        try raw.write(to: root.appendingPathComponent("requests.json"))
        let result = try XCTUnwrap(DesktopOwnedAppDataFileReader.read(
            "requests.json", appDirectory: root, maximumBytes: UInt64(raw.count)
        ))
        XCTAssertEqual(result.data, raw)
        try DesktopOwnedAppDataFileReader.revalidate(result.receipt)
        let invalid = Data([0xFF, 0, 0xFE])
        try invalid.write(to: root.appendingPathComponent("requests.json"))
        let undecoded = try XCTUnwrap(DesktopOwnedAppDataFileReader.read(
            "requests.json", appDirectory: root, maximumBytes: 3
        ))
        XCTAssertEqual(undecoded.data, invalid)
    }

    func testAbsenceAndEmptyFile_AreDistinctAndDoNotCreateDirectories() throws {
        let root = try directory()
        XCTAssertNil(try DesktopOwnedAppDataFileReader.read(
            "VoiceUsage/requests.json", appDirectory: root, maximumBytes: 2_097_152
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("VoiceUsage").path))
        try Data().write(to: root.appendingPathComponent("empty.json"))
        let empty = try XCTUnwrap(DesktopOwnedAppDataFileReader.read(
            "empty.json", appDirectory: root, maximumBytes: 0
        ))
        XCTAssertEqual(empty.data, Data())
    }

    func testConfiguredBudget_RejectsOversizeButAdmitsExactBoundary() throws {
        let root = try directory()
        try Data([1, 2, 3]).write(to: root.appendingPathComponent("requests.json"))
        XCTAssertThrowsError(try DesktopOwnedAppDataFileReader.read(
            "requests.json", appDirectory: root, maximumBytes: 2
        )) { guard case DesktopOwnedAppDataFileReadError.exceedsByteBudget = $0 else {
            return XCTFail("Unexpected budget error: \($0)")
        } }
        XCTAssertEqual(try DesktopOwnedAppDataFileReader.read(
            "requests.json", appDirectory: root, maximumBytes: 3
        )?.data, Data([1, 2, 3]))
    }

    func testRelativePaths_RejectExternalTraversalAliasesAndNonlocalRoots() throws {
        let root = try directory()
        for path in ["", "/requests.json", "../requests.json", "./requests.json", "VoiceUsage//requests.json",
                     "VoiceUsage/../requests.json", "C:\\requests.json", "file:requests.json",
                     "VoiceUsage./requests.json", "VoiceUsage /requests.json", "requests\0.json"] {
            XCTAssertThrowsError(try DesktopOwnedAppDataFileReader.read(
                path, appDirectory: root, maximumBytes: 2_097_152
            ))
        }
        let remote = try XCTUnwrap(URL(string: "https://example.invalid/owned"))
        XCTAssertThrowsError(try DesktopOwnedAppDataFileReader.read(
            "requests.json", appDirectory: remote, maximumBytes: 1
        ))
    }

    func testMetadataReceipt_RejectsReplacementAndSourceDisappearance() throws {
        let root = try directory()
        let file = root.appendingPathComponent("requests.json")
        try Data("first".utf8).write(to: file)
        let result = try XCTUnwrap(DesktopOwnedAppDataFileReader.read(
            "requests.json", appDirectory: root, maximumBytes: 100
        ))
        try Data("other".utf8).write(to: file, options: [.atomic])
        XCTAssertThrowsError(try DesktopOwnedAppDataFileReader.revalidate(result.receipt))
        try FileManager.default.removeItem(at: file)
        XCTAssertThrowsError(try DesktopOwnedAppDataFileReader.revalidate(result.receipt))
    }

    func testChunkCancellationAndGrowth_AreExplicitAndPreserveCancellationCadence() throws {
        let root = try directory()
        let file = root.appendingPathComponent("requests.json")
        try Data(repeating: 7, count: 200_000).write(to: file)
        var checks = 0
        XCTAssertThrowsError(try DesktopOwnedAppDataFileReader.read(
            "requests.json", appDirectory: root, maximumBytes: 200_000, checkCancellation: {
                checks += 1
                if checks == 4 { throw CancellationError() }
            }
        )) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(checks, 4)
        checks = 0
        XCTAssertThrowsError(try DesktopOwnedAppDataFileReader.read(
            "requests.json", appDirectory: root, maximumBytes: 200_001, checkCancellation: {
                checks += 1
                if checks == 3 {
                    let handle = try FileHandle(forWritingTo: file)
                    try handle.seekToEnd()
                    try handle.write(contentsOf: Data([1]))
                    try handle.close()
                }
            }
        )) { guard case DesktopOwnedAppDataFileReadError.grewSource = $0 else {
            return XCTFail("Unexpected growth error: \($0)")
        } }
    }

    func testPostReadDisappearance_PreservesOriginalCocoaErrorInformation() throws {
        let root = try directory()
        let file = root.appendingPathComponent("requests.json")
        try Data("source".utf8).write(to: file)
        var checks = 0
        var expected: NSError?
        XCTAssertThrowsError(try DesktopVocabularyMigrationSource.read(
            "requests.json", root: root, checkCancellation: {
                checks += 1
                if checks == 3 {
                    try FileManager.default.removeItem(at: file)
                    do { _ = try DesktopRecordingStore.audioCleanupIdentity(at: file) } catch {
                        expected = error as NSError
                    }
                }
            }
        )) {
            let actual = $0 as NSError
            XCTAssertEqual(actual.domain, expected?.domain)
            XCTAssertEqual(actual.code, expected?.code)
            XCTAssertEqual(actual.localizedDescription, expected?.localizedDescription)
            XCTAssertEqual(actual.userInfo[NSFilePathErrorKey] as? String,
                           expected?.userInfo[NSFilePathErrorKey] as? String)
        }
        XCTAssertNotNil(expected)
    }

    func testVocabularyAdapter_PreservesExistingDiagnosticsIncludingCloseFailure() {
        let cases: [(DesktopOwnedAppDataFileReadError, String)] = [
            (.unsafeFile, "A vocabulary source is linked, non-regular, or has unreadable ownership."),
            (.unsafeDirectory, "Vocabulary storage must be an owned non-linked directory."),
            (.exceedsByteBudget, "A vocabulary store exceeds the JSON size limit."),
            (.changedSource, "A vocabulary source changed during collection."),
            (.grewSource, "A vocabulary source grew during collection.")
        ]
        for (error, message) in cases {
            XCTAssertEqual(DesktopVocabularyMigrationSource.vocabularyError(error).localizedDescription, message)
        }
        let cleanup = CocoaError(.fileReadUnknown)
        let error = DesktopOwnedAppDataFileReadError.closeFailure(
            original: DesktopOwnedAppDataFileReadError.grewSource, cleanup: cleanup
        )
        XCTAssertEqual(DesktopVocabularyMigrationSource.vocabularyError(error).localizedDescription,
                       "A vocabulary source grew during collection. The vocabulary source could not be closed: "
                        + cleanup.localizedDescription)
    }
}
