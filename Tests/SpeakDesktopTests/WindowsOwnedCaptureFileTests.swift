#if canImport(SpeakWindowsPlatform)
import Foundation
import SpeakCore
import SpeakDesktop
import SpeakWindowsPlatform
import XCTest

final class WindowsOwnedCaptureFileTests: XCTestCase {
    func testNativeHeldWriterPreservesBothPCMRatesAndRetainedLifetime() throws {
        try requireWindows()
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for rate in [16_000, 24_000] {
            let owned = try DesktopOwnedCaptureFile.create(
                in: root, using: WindowsOwnedCaptureFile.qualificationFactory
            )
            let file = try PCMRecordingFile(ownedFile: owned, sampleRate: rate)
            let pcm = Data(repeating: 17, count: rate / 5)
            try file.append(pcm)
            XCTAssertEqual(try file.finish(), 0.1, accuracy: 1e-9)
            XCTAssertEqual(try Data(contentsOf: owned.url), PCMWaveWriter.wavData(pcm: pcm, sampleRate: rate))
            try owned.close()
            XCTAssertThrowsError(try owned.discard())
            XCTAssertTrue(FileManager.default.fileExists(atPath: owned.url.path))
        }
    }

    func testNativeCollisionHasExactlyOneOwner() async throws {
        try requireWindows()
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directoryID = UUID()
        let count = await withTaskGroup(of: Int.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    do {
                        let owned = try DesktopOwnedCaptureFile.create(
                            in: root, directoryID: directoryID, using: WindowsOwnedCaptureFile.qualificationFactory
                        )
                        try owned.discard()
                        return 1
                    } catch { return 0 }
                }
            }
            var count = 0
            for await value in group { count += value }
            return count
        }
        XCTAssertEqual(count, 1)
    }

    func testNativeCancellationOnlyRemovesItsOwnedUnpublishedFile() throws {
        try requireWindows()
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let unrelated = root.appendingPathComponent("unrelated.wav")
        let sentinel = Data([9, 8, 7])
        try sentinel.write(to: unrelated)
        var checks = 0
        XCTAssertThrowsError(try DesktopOwnedCaptureFile.create(
            in: root, using: WindowsOwnedCaptureFile.qualificationFactory,
            checkCancellation: {
                checks += 1
                if checks == 2 { throw CancellationError() }
            }
        )) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(try Data(contentsOf: unrelated), sentinel)
        let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0 != unrelated }
        XCTAssertEqual(folders.count, 1)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: XCTUnwrap(folders.first).path).isEmpty)
    }

    func testNativeAnchorsACLReparseAndReplacementFixture() throws {
        try requireWindows()
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try WindowsOwnedCaptureFile.runQualificationFixture(in: root)
    }

    func testSharedDefaultRemainsUnavailableOnWindows() throws {
        try requireWindows()
        XCTAssertThrowsError(try DesktopOwnedCaptureFile.create(
            in: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        )) {
            guard case DesktopOwnedCaptureError.unsupportedPlatform = $0 else {
                return XCTFail("Native qualification must not enable the host/default route: \($0)")
            }
        }
    }

    private func requireWindows() throws {
        #if !os(Windows)
        throw XCTSkip("Requires real Windows held handles; the stub graph is only a type check.")
        #endif
    }

    private func makeRoot() throws -> URL {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("windows-owned-capture-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
#endif
