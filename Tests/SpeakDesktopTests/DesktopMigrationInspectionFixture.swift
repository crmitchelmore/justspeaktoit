import Foundation
import XCTest
import SpeakCore
@testable import SpeakDesktop

struct InspectionFixture: Sendable {
    let root: URL
    var source: URL { root.appendingPathComponent("Chosen backup.zip") }
    static let digests = LocalModelDigestProvider(name: "Synthetic fixed digest; not cryptographic proof") {
        InspectionDigest()
    }
    static let storage = DesktopMigrationArchive.Storage(
        createDirectory: {
            try FileManager.default.createDirectory(
                at: $0, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
            )
        },
        createFile: {
            guard FileManager.default.createFile(
                atPath: $0.path, contents: Data(), attributes: [.posixPermissions: 0o600]
            ) else { throw CocoaError(.fileWriteUnknown) }
        }
    )

    var reader: DesktopMigrationInspection.Reader {
        .init { try DesktopMigrationArchive.read(
            $0, digests: Self.digests, stagingRoot: root, storage: Self.storage
        ) }
    }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("inspection-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    func staging() throws -> URL {
        let directory = root.appendingPathComponent("migration-\(UUID())", isDirectory: true)
        try Self.storage.createDirectory(directory)
        return directory
    }

    func snapshot(directory: URL?) -> DataMigrationSnapshot {
        .init(manifest: .init(categories: [.history], scopes: [:]), records: [.history: []], directory: directory)
    }

    func remove() {
        do { try FileManager.default.removeItem(at: root) } catch { XCTFail(error.localizedDescription) }
    }
}

final class InspectionDigest: LocalModelSHA256Hasher {
    func update(_ bytes: UnsafeRawBufferPointer) throws { try Task.checkCancellation() }
    func finish() throws -> String { String(repeating: "a", count: 64) }
}
