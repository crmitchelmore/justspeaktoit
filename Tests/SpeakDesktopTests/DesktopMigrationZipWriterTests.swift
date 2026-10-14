import Foundation
import SpeakCore
import XCTest
@testable import SpeakDesktop

final class DesktopMigrationZipWriterTests: XCTestCase {
    private func file() throws -> (URL, FileHandle) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("writer.zip")
        try Data().write(to: file, options: .withoutOverwriting)
        return (file, try FileHandle(forWritingTo: file))
    }

    func testIndexMemoryAndEntryBudgets_FailExplicitly() throws {
        let (_, handle) = try file()
        defer { try? handle.close() }
        XCTAssertThrowsError(try DesktopMigrationZipWriter(file: handle, indexMemoryBudget: 1)) { error in
            XCTAssertTrue(error.localizedDescription.contains("memory budget"), error.localizedDescription)
        }
        let writer = try DesktopMigrationZipWriter(file: handle, maximumEntries: 1)
        try writer.add(Data(), path: "first.json")
        XCTAssertThrowsError(try writer.add(Data(), path: "second.json")) { error in
            XCTAssertTrue(error.localizedDescription.contains("too many entries"), error.localizedDescription)
        }
        XCTAssertThrowsError(try writer.finish())
    }

    func testClosedDestination_ReportsIOFailureInsteadOfSuccessfulExport() throws {
        let (_, handle) = try file()
        let writer = try DesktopMigrationZipWriter(file: handle)
        try handle.close()
        XCTAssertThrowsError(try writer.add(Data([1, 2, 3]), path: "settings.json"))
    }

    func testDuplicatePathsAndPostFinalizationMutation_AreRejected() throws {
        let (_, handle) = try file()
        defer { try? handle.close() }
        let writer = try DesktopMigrationZipWriter(file: handle)
        try writer.add(Data([1]), path: "settings.json")
        XCTAssertThrowsError(try writer.add(Data([2]), path: "settings.json"))
        try writer.finish()
        XCTAssertThrowsError(try writer.finish())
        XCTAssertThrowsError(try writer.add(Data([3]), path: "history.json"))
    }

    func testIncrementalBudget_UsesExactLimitsWithoutAllocatingEntryContents() throws {
        var budget = DataMigrationArchivePolicy.EntryBudget()
        try budget.admit(.init(path: "first", uncompressedBytes: 20_000_000_000))
        try budget.admit(.init(path: "second", uncompressedBytes: 20_000_000_000))
        try budget.admit(.init(path: "third", uncompressedBytes: 10_000_000_000))
        XCTAssertEqual(budget.bytes, 50_000_000_000)
        XCTAssertThrowsError(try budget.admit(.init(path: "over", uncompressedBytes: 1)))
        XCTAssertThrowsError(try budget.admit(.init(path: "oversized", uncompressedBytes: 20_000_000_001)))
        XCTAssertThrowsError(try budget.admit(.init(path: "first", uncompressedBytes: 0)))
        XCTAssertEqual(budget.bytes, 50_000_000_000)
        var entries = DataMigrationArchivePolicy.EntryBudget()
        for index in 0..<100_000 { try entries.admit(.init(path: String(index), uncompressedBytes: 0)) }
        XCTAssertThrowsError(try entries.admit(.init(path: "last", uncompressedBytes: 0)))
    }
}
