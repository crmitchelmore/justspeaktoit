import Foundation
import XCTest
import SpeakDesktop

final class DesktopFilePublicationTests: XCTestCase {
    func testCommit_PublishesRegularIndependentFileAndConsumesOnlyOwnedStaging() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent("owned.partial")
        let destination = root.appendingPathComponent("published.bin")
        let bytes = Data("Synthetic publication bytes".utf8)
        try bytes.write(to: staging, options: .withoutOverwriting)
        try DesktopFilePublication.commit(staging: staging, destination: destination)
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeRegular)
        XCTAssertEqual((attributes[.referenceCount] as? NSNumber)?.intValue, 1)
    }

    func testCommit_ExistingDestinationPreservesBothCallerFiles() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent("owned.partial")
        let destination = root.appendingPathComponent("existing.bin")
        let source = Data("Synthetic staged bytes".utf8)
        let existing = Data("Synthetic existing bytes".utf8)
        try source.write(to: staging)
        try existing.write(to: destination)
        XCTAssertThrowsError(try DesktopFilePublication.commit(staging: staging, destination: destination))
        XCTAssertEqual(try Data(contentsOf: staging), source)
        XCTAssertEqual(try Data(contentsOf: destination), existing)
    }

    func testCommit_IdenticalPathAndMissingSourceNeverRemoveOrReplaceData() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("owned.bin")
        let bytes = Data("Synthetic retained bytes".utf8)
        try bytes.write(to: file)
        XCTAssertThrowsError(try DesktopFilePublication.commit(staging: file, destination: file))
        XCTAssertThrowsError(try DesktopFilePublication.commit(
            staging: root.appendingPathComponent("missing.partial"), destination: file
        ))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testCommit_NonSiblingDestinationPreservesStagingWithoutCrossDeviceCopy() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let other = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        let staging = root.appendingPathComponent("owned.partial")
        let destination = other.appendingPathComponent("published.bin")
        let bytes = Data("Synthetic sibling-only publication".utf8)
        try bytes.write(to: staging)
        XCTAssertThrowsError(try DesktopFilePublication.commit(staging: staging, destination: destination))
        XCTAssertEqual(try Data(contentsOf: staging), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "file publication-\(UUID())-\u{00E9}-\u{1F600}"
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
}
