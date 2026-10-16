import Foundation
import XCTest
import SpeakDesktop
import SpeakDesktopHost

final class DesktopComparisonStoreLoadingTests: XCTestCase {
    func testConcurrentInitializationSharesOneStoreAndPrunesOnlyOrphanSamples() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let samples = root.appendingPathComponent("Comparisons/Samples")
        try FileManager.default.createDirectory(at: samples, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let orphan = samples.appendingPathComponent(UUID().uuidString + ".wav")
        try Data([1, 2]).write(to: orphan)
        let unrelated = samples.appendingPathComponent("unrecognized.wav")
        try Data([3, 4]).write(to: unrelated)
        let controller = try DesktopHostController<FakePlatform>(
            directory: root, effects: GatedEffects(gate: Gate(open: true))
        )
        async let first = controller.loadComparisonStore()
        async let second = controller.loadComparisonStore()
        let (one, two) = try await (first, second)
        XCTAssertTrue(one === two)
        let installed = await controller.comparisons
        XCTAssertTrue(installed === one)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertEqual(try Data(contentsOf: unrelated), Data([3, 4]))
        await controller.close()
    }

    func testClosedHostDoesNotInitializeComparisonStorage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = try DesktopHostController<FakePlatform>(
            directory: root, effects: GatedEffects(gate: Gate(open: true))
        )
        await controller.close()
        do {
            _ = try await controller.loadComparisonStore()
            XCTFail("Closed comparison initialization must be refused")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Comparisons").path))
    }
}
