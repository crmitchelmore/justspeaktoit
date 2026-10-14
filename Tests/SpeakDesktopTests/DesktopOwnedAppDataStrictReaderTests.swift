import Foundation
import XCTest
@testable import SpeakDesktop

final class DesktopOwnedAppDataStrictReaderTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }

    private func read(_ root: URL, path: String = "requests.json", budget: UInt64 = 2_097_152) throws
        -> DesktopOwnedAppDataFileReader.StrictSnapshot {
        try DesktopOwnedAppDataFileReader.readStrict(path, appDirectory: root, maximumBytes: budget)
    }

    func testStrictRead_BindsRawBytesAndSupportsSendableRevalidationClosure() async throws {
        let root = try directory()
        let raw = Data("[{\"second\":true}, {\"first\":null}]\r\n".utf8)
        try raw.write(to: root.appendingPathComponent("requests.json"))
        let snapshot = try read(root)
        XCTAssertEqual(snapshot.data, raw)
        var callerCopy = try XCTUnwrap(snapshot.data)
        callerCopy.append(1)
        let revalidate: @Sendable () throws -> Void = {
            try DesktopOwnedAppDataFileReader.revalidateStrict(snapshot.receipt)
        }
        try await Task.detached { try revalidate() }.value
        XCTAssertEqual(snapshot.data, raw)
    }

    func testSameSizeAndTimestampByteEdit_IsNotAcceptedAsUnchanged() throws {
        let root = try directory()
        let file = root.appendingPathComponent("requests.json")
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        try Data("first".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: file.path)
        let snapshot = try read(root)
        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: Data("other".utf8))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: file.path)
        let current = try XCTUnwrap(DesktopOwnedAppDataFileReader.strictSourceIdentity(file))
        let captured = try XCTUnwrap(snapshot.receipt.identity)
        XCTAssertEqual(current.size, captured.size)
        XCTAssertEqual(current.modified, captured.modified)
        XCTAssertEqual(current.device, captured.device)
        XCTAssertEqual(current.file, captured.file)
        XCTAssertThrowsError(try DesktopOwnedAppDataFileReader.revalidateStrict(snapshot.receipt))
    }

    func testByteBinding_RejectsDifferentBytesWithOtherwiseMatchingReceiptMetadata() throws {
        let root = try directory()
        try Data("other".utf8).write(to: root.appendingPathComponent("requests.json"))
        let current = try read(root)
        let receipt = DesktopOwnedAppDataFileReader.StrictReceipt(
            location: current.receipt.location, maximumBytes: current.receipt.maximumBytes,
            data: Data("first".utf8), identity: current.receipt.identity, chain: current.receipt.chain
        )
        try DesktopOwnedAppDataFileReader.revalidateStrict(current.receipt)
        XCTAssertThrowsError(try DesktopOwnedAppDataFileReader.revalidateStrict(receipt)) {
            guard case DesktopOwnedAppDataFileReadError.changedSource = $0 else {
                return XCTFail("Unexpected byte-binding error: \($0)")
            }
        }
    }

    func testParentReplacement_IsRejectedEvenWhenOriginalFileIsMovedBack() throws {
        let root = try directory()
        let parent = root.appendingPathComponent("VoiceUsage")
        let moved = try directory().appendingPathComponent("moved")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        try Data("same".utf8).write(to: parent.appendingPathComponent("requests.json"))
        let snapshot = try read(root, path: "VoiceUsage/requests.json")
        try FileManager.default.moveItem(at: parent, to: moved)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        try FileManager.default.moveItem(at: moved.appendingPathComponent("requests.json"),
                                        to: parent.appendingPathComponent("requests.json"))
        XCTAssertEqual(try Data(contentsOf: parent.appendingPathComponent("requests.json")), snapshot.data)
        XCTAssertThrowsError(try DesktopOwnedAppDataFileReader.revalidateStrict(snapshot.receipt))
    }

    func testMissingParentAppearance_IsRejectedWithoutCreatingOrReadingInventedData() throws {
        let root = try directory()
        let snapshot = try read(root, path: "VoiceUsage/requests.json")
        XCTAssertNil(snapshot.data)
        try DesktopOwnedAppDataFileReader.revalidateStrict(snapshot.receipt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("VoiceUsage").path))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("VoiceUsage"),
                                                withIntermediateDirectories: false)
        XCTAssertThrowsError(try DesktopOwnedAppDataFileReader.revalidateStrict(snapshot.receipt))
        let source = root.appendingPathComponent("VoiceUsage/requests.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }

    func testAbsentSourceAppearanceAndPresentSourceDisappearance_AreRejected() throws {
        let root = try directory()
        let absent = try read(root)
        XCTAssertNil(absent.data)
        try Data().write(to: root.appendingPathComponent("requests.json"))
        XCTAssertThrowsError(try DesktopOwnedAppDataFileReader.revalidateStrict(absent.receipt))
        let present = try read(root, budget: 0)
        XCTAssertEqual(present.data, Data())
        try FileManager.default.removeItem(at: root.appendingPathComponent("requests.json"))
        XCTAssertThrowsError(try DesktopOwnedAppDataFileReader.revalidateStrict(present.receipt))
    }

    func testMissingRoot_CannotProduceAnUnanchoredStrictAbsenceReceipt() throws {
        let parent = try directory()
        let root = parent.appendingPathComponent("not-created")
        XCTAssertThrowsError(try read(root)) {
            guard case DesktopOwnedAppDataFileReadError.insufficientIdentity = $0 else {
                return XCTFail("Unexpected unanchored absence error: \($0)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testGrowthBeyondCapturedBudgetAndCancellation_StopBoundedReread() throws {
        let root = try directory()
        let file = root.appendingPathComponent("requests.json")
        try Data(repeating: 1, count: 200_000).write(to: file)
        let snapshot = try read(root, budget: 200_000)
        var checks = 0
        XCTAssertThrowsError(try DesktopOwnedAppDataFileReader.revalidateStrict(
            snapshot.receipt, checkCancellation: {
                checks += 1
                if checks == 7 { throw CancellationError() }
            }
        )) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(checks, 7)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([2]))
        try handle.close()
        XCTAssertThrowsError(try DesktopOwnedAppDataFileReader.revalidateStrict(snapshot.receipt))
        XCTAssertEqual(try Data(contentsOf: file).count, 200_001)
    }

    func testInsufficientFileIdentity_FailsRatherThanClaimingStrictBinding() {
        for identity in [
            DesktopRecordingAudioSnapshot.Identity(size: 1, modified: Date(), created: nil, device: nil, file: 1),
            DesktopRecordingAudioSnapshot.Identity(size: 1, modified: Date(), created: nil, device: 1, file: nil),
            DesktopRecordingAudioSnapshot.Identity(size: 1, modified: Date(), created: nil, device: 1, file: 0)
        ] {
            XCTAssertThrowsError(try DesktopOwnedAppDataFileReader.requireStrictIdentity(identity)) {
                guard case DesktopOwnedAppDataFileReadError.insufficientIdentity = $0 else {
                    return XCTFail("Unexpected unsupported identity error: \($0)")
                }
            }
        }
    }

    #if !os(Windows)
    func testSymlinkRetargetAndHardLinkAddition_AreNotAcceptedAsOwnedSources() throws {
        let root = try directory()
        let file = root.appendingPathComponent("requests.json")
        let external = try directory()
        try Data("same".utf8).write(to: file)
        let snapshot = try read(root)
        try FileManager.default.linkItem(at: file, to: external.appendingPathComponent("linked"))
        XCTAssertThrowsError(try DesktopOwnedAppDataFileReader.revalidateStrict(snapshot.receipt))
        try FileManager.default.removeItem(at: external.appendingPathComponent("linked"))
        try FileManager.default.removeItem(at: file)
        try Data("same".utf8).write(to: external.appendingPathComponent("other"))
        try FileManager.default.createSymbolicLink(at: file,
                                                   withDestinationURL: external.appendingPathComponent("other"))
        XCTAssertThrowsError(try DesktopOwnedAppDataFileReader.revalidateStrict(snapshot.receipt))
    }

    func testParentSymlinkRetarget_IsRejectedBeforeCallerGetsNewBytes() throws {
        let root = try directory()
        let parent = root.appendingPathComponent("VoiceUsage")
        let external = try directory()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        try Data("original".utf8).write(to: parent.appendingPathComponent("requests.json"))
        let snapshot = try read(root, path: "VoiceUsage/requests.json")
        try FileManager.default.removeItem(at: parent.appendingPathComponent("requests.json"))
        try FileManager.default.removeItem(at: parent)
        try Data("replacement".utf8).write(to: external.appendingPathComponent("requests.json"))
        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: external)
        XCTAssertThrowsError(try DesktopOwnedAppDataFileReader.revalidateStrict(snapshot.receipt))
    }
    #endif
}
