import Foundation
import SpeakCore
import SpeakDesktop
import XCTest
#if os(Windows)
import SpeakWindowsPlatform
#endif

final class DesktopNativeRetainedCapsuleTests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }

    private var storage: DesktopMigrationArchive.Storage? {
        #if os(Windows)
        WindowsMigrationArchive.storage
        #else
        nil
        #endif
    }

    private var publication: DesktopFilePublication.Copy {
        #if os(Windows)
        .init { try WindowsMigrationArchive.publish($0, to: $1) }
        #else
        .init { source, destination in
            let temporary = destination.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
            try FileManager.default.copyItem(at: source, to: temporary)
            try DesktopFilePublication.commit(staging: temporary, destination: destination)
        }
        #endif
    }

    private func archive(
        _ values: [String: AnyCodable] = [:], platform: DesktopNativeConfigurationCapture.Platform = .windows
    ) throws -> DesktopNativeConfigurationArchive {
        try DesktopNativeConfigurationArchiveCodec.project(.capture(
            values, platform: platform, selectedFields: Set(DesktopNativeConfigurationField.allCases.map(\.rawValue))
        ))
    }

    func testPersistRestartAndExport_PreserveSourceAndPresenceWithoutSettingsMutation() throws {
        let root = try root()
        let original = try archive([
            "postProcessing.customPrompt": AnyCodable(.string("  native\nprompt  ")),
            "configuration.postProcessingSystemPrompt": AnyCodable(.string("")),
            "microphoneDeviceID": AnyCodable(.null), "localUseGPU": AnyCodable(.bool(false)),
            "hotKey": AnyCodable(.object(["modifiers": .int(0), "virtualKey": .int(0), "style": .string("future")]))
        ])
        let capsule = try DesktopNativeRetainedCapsule.create(
            original, in: root, storage: storage, publication: publication
        )
        XCTAssertEqual(try capsule.reload().records, original.records)
        XCTAssertEqual(try DesktopNativeRetainedCapsule.read(from: capsule.directory).records, original.records)
        let export = try capsule.exportProjection()
        XCTAssertEqual(export.records[.settings], original.records)
        XCTAssertEqual(export.manifest.scopes["settings"]?.selectedIDs, original.coverage.keys)
        XCTAssertFalse(try XCTUnwrap(export.manifest.scopes["settings"]).isComplete)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: capsule.directory.path),
                       [DesktopNativeRetainedCapsule.filename])
        #if !os(Windows)
        let attributes = try FileManager.default.attributesOfItem(atPath: capsule.directory.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        #endif
    }

    func testExistingLeafReuse_RefusesWithoutDeletingOrOverwritingOriginal() throws {
        let root = try root()
        let identifier = UUID()
        let original = try archive(["postProcessing.customPrompt": AnyCodable(.string("original"))])
        let first = try DesktopNativeRetainedCapsule.create(
            original, in: root, identifier: identifier, storage: storage, publication: publication
        )
        XCTAssertThrowsError(try DesktopNativeRetainedCapsule.create(
            archive(), in: root, identifier: identifier, storage: storage, publication: publication
        ))
        XCTAssertEqual(try first.reload().records, original.records)
    }

    func testEmptyCapture_IsNewImmutableCapsuleAndCannotClearExistingCapsule() throws {
        let root = try root()
        let original = try archive(["postProcessing.customPrompt": AnyCodable(.string("retained"))])
        let first = try DesktopNativeRetainedCapsule.create(
            original, in: root, storage: storage, publication: publication
        )
        let empty = try DesktopNativeConfigurationArchiveCodec.project(.capture([:], platform: .linux))
        let second = try DesktopNativeRetainedCapsule.create(
            empty, in: root, storage: storage, publication: publication
        )
        XCTAssertNotEqual(first.directory, second.directory)
        XCTAssertEqual(try first.reload().records, original.records)
        XCTAssertTrue(try second.reload().records.isEmpty)
        XCTAssertEqual(try second.exportProjection().manifest.scopes["settings"]?.selectedIDs, [])
    }

    func testChangedValidBytesAndDamagedBytes_AreNotReportedAsOriginalRetention() throws {
        let root = try root()
        let capsule = try DesktopNativeRetainedCapsule.create(
            archive(), in: root, storage: storage, publication: publication
        )
        let file = capsule.directory.appendingPathComponent(DesktopNativeRetainedCapsule.filename)
        let changed = try DesktopNativeConfigurationArchiveCodec.encode(
            archive(["postProcessing.customPrompt": AnyCodable(.string("changed"))])
        )
        try changed.write(to: file)
        XCTAssertThrowsError(try capsule.reload())
        // A restart validates current bytes, not an unavailable historical authenticity or write-CAS receipt.
        XCTAssertEqual(try DesktopNativeRetainedCapsule.read(from: capsule.directory).records,
                       try archive(["postProcessing.customPrompt": AnyCodable(.string("changed"))]).records)
        try Data("{damaged".utf8).write(to: file)
        XCTAssertThrowsError(try DesktopNativeRetainedCapsule.read(from: capsule.directory))
        XCTAssertThrowsError(try capsule.exportProjection())
    }

    func testPrecancelAndMidconstructionCancel_LeaveNoUnpublishedCapsule() throws {
        let root = try root()
        let source = try archive()
        XCTAssertThrowsError(try DesktopNativeRetainedCapsule.create(
            source, in: root, storage: storage, publication: publication,
            checkCancellation: { throw CancellationError() }
        )) { XCTAssertTrue($0 is CancellationError) }
        let cancel = DesktopFilePublication.Copy { _, _ in throw CancellationError() }
        XCTAssertThrowsError(try DesktopNativeRetainedCapsule.create(
            source, in: root, storage: storage, publication: cancel
        )) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testFailedWriteAndPublication_CleanupOnlyOwnedUnpublishedLeaf() throws {
        let root = try root()
        let broken = DesktopMigrationArchive.Storage(
            createDirectory: { try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: false) },
            createFile: { _ in throw CapsuleFixtureError.refused }
        )
        XCTAssertThrowsError(try DesktopNativeRetainedCapsule.create(
            archive(), in: root, storage: broken, publication: publication
        ))
        let failed = DesktopFilePublication.Copy { _, _ in throw CapsuleFixtureError.refused }
        XCTAssertThrowsError(try DesktopNativeRetainedCapsule.create(
            archive(), in: root, storage: storage, publication: failed
        ))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testPublishedCompletionFailure_IsExplicitAndNeverDeletesOrRetriesPublishedData() throws {
        let root = try root()
        let source = try archive()
        let real = publication
        let incomplete = DesktopFilePublication.Copy { staging, destination in
            try DesktopFilePublication.copy(source: staging, destination: destination, using: real)
            throw DesktopFilePublication.CopyCompletionFailure(destination: destination, detail: "Synthetic flush")
        }
        XCTAssertThrowsError(try DesktopNativeRetainedCapsule.create(
            source, in: root, storage: storage, publication: incomplete
        )) {
            let failure = $0 as? DesktopNativeRetentionPublishedFailure
            XCTAssertTrue(failure?.underlyingError is DesktopFilePublication.CopyCompletionFailure)
        }
        let directories = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        )
        XCTAssertEqual(directories.count, 1)
        let retained = try DesktopNativeRetainedCapsule.read(from: XCTUnwrap(directories.first))
        XCTAssertEqual(retained.records, source.records)
    }

    func testUnrelatedChildOnFailure_IsNeverRecursivelyDeletedByCleanup() throws {
        let root = try root()
        let failed = DesktopFilePublication.Copy { staging, _ in
            let unrelated = staging.deletingLastPathComponent().appendingPathComponent("unrelated.txt")
            try Data("synthetic unrelated child".utf8).write(to: unrelated)
            throw CapsuleFixtureError.refused
        }
        XCTAssertThrowsError(try DesktopNativeRetainedCapsule.create(
            archive(), in: root, storage: storage, publication: failed
        ))
        let leaf = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ).first)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: leaf.path), ["unrelated.txt"])
    }

    func testChangedAtPublication_IsReportedWithPublishedEffectNotOriginalSuccess() throws {
        let root = try root()
        let real = publication
        let changed = try DesktopNativeConfigurationArchiveCodec.encode(
            archive(["postProcessing.customPrompt": AnyCodable(.string("changed during publication"))])
        )
        let mutate = DesktopFilePublication.Copy { staging, destination in
            try changed.write(to: staging)
            try DesktopFilePublication.copy(source: staging, destination: destination, using: real)
        }
        XCTAssertThrowsError(try DesktopNativeRetainedCapsule.create(
            archive(), in: root, storage: storage, publication: mutate
        )) { XCTAssertTrue($0 is DesktopNativeRetentionPublishedFailure) }
    }

    func testCancellationAfterPublication_KeepsCompleteCapsuleAndUnrelatedFilesWithoutRetry() async throws {
        let root = try root()
        let unrelated = root.appendingPathComponent("unrelated.bin")
        let counter = root.appendingPathComponent("publication-count.bin")
        let unrelatedBytes = Data("synthetic unrelated bytes".utf8)
        try unrelatedBytes.write(to: unrelated)
        try Data().write(to: counter)
        let original = try archive(["postProcessing.customPrompt": AnyCodable(.string("original source"))])
        let real = publication
        let storage = storage
        let cancelled = DesktopFilePublication.Copy { staging, destination in
            try DesktopFilePublication.copy(source: staging, destination: destination, using: real)
            let handle = try FileHandle(forWritingTo: counter)
            _ = try handle.seekToEnd()
            try handle.write(contentsOf: Data("one publication\n".utf8))
            try handle.close()
            let sidecar = destination.deletingLastPathComponent().appendingPathComponent("unrelated-sidecar.bin")
            try unrelatedBytes.write(to: sidecar)
            withUnsafeCurrentTask { $0?.cancel() }
        }
        let task = Task {
            try DesktopNativeRetainedCapsule.create(original, in: root, storage: storage, publication: cancelled)
        }
        do {
            _ = try await task.value
            XCTFail("Post-publication cancellation must report the committed-effect uncertainty.")
        } catch let failure as DesktopNativeRetentionPublishedFailure {
            XCTAssertTrue(failure.underlyingError is CancellationError)
            let restart = try DesktopNativeRetainedCapsule.read(from: failure.directory)
            XCTAssertEqual(restart.records, original.records)
            XCTAssertEqual(try Data(contentsOf: counter), Data("one publication\n".utf8))
            XCTAssertEqual(try Data(contentsOf: unrelated), unrelatedBytes)
            let sidecar = failure.directory.appendingPathComponent("unrelated-sidecar.bin")
            XCTAssertEqual(try Data(contentsOf: sidecar), unrelatedBytes)
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: failure.directory.appendingPathComponent("unpublished.json").path
            ))
        }
    }
}

extension DesktopNativeRetainedCapsuleTests {
    func testStagingReplacedByDirectoryBeforePublicationFailure_PreservesChildAndBothErrors() throws {
        let root = try root()
        let failed = DesktopFilePublication.Copy { staging, _ in
            try FileManager.default.removeItem(at: staging)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
            try Data("sentinel".utf8).write(to: staging.appendingPathComponent("unrelated.bin"))
            throw CapsuleFixtureError.refused
        }
        XCTAssertThrowsError(try DesktopNativeRetainedCapsule.create(
            archive(), in: root, storage: storage, publication: failed
        )) {
            let failure = $0 as? DesktopNativeRetentionCleanupFailure
            XCTAssertTrue(failure?.primaryError is CapsuleFixtureError)
            XCTAssertTrue(failure?.cleanupError is CocoaError)
            XCTAssertFalse($0.localizedDescription.contains("unrelated.bin"))
        }
        let leaf = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ).first)
        let sentinel = leaf.appendingPathComponent("unpublished.json").appendingPathComponent("unrelated.bin")
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("sentinel".utf8))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: leaf.appendingPathComponent(DesktopNativeRetainedCapsule.filename).path
        ))
    }

    func testStagingReplacedByDirectoryAfterPublication_PreservesChildAndPublishedEnvelope() throws {
        let root = try root()
        let original = try archive(["postProcessing.customPrompt": AnyCodable(.string("original"))])
        let real = publication
        let changed = DesktopFilePublication.Copy { staging, destination in
            try DesktopFilePublication.copy(source: staging, destination: destination, using: real)
            try FileManager.default.removeItem(at: staging)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
            try Data("sentinel".utf8).write(to: staging.appendingPathComponent("unrelated.bin"))
        }
        XCTAssertThrowsError(try DesktopNativeRetainedCapsule.create(
            original, in: root, storage: storage, publication: changed
        )) {
            let failure = $0 as? DesktopNativeRetentionPublishedFailure
            XCTAssertTrue(failure?.underlyingError is CocoaError)
        }
        let leaf = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ).first)
        let sentinel = leaf.appendingPathComponent("unpublished.json").appendingPathComponent("unrelated.bin")
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("sentinel".utf8))
        XCTAssertEqual(try DesktopNativeRetainedCapsule.read(from: leaf).records, original.records)
    }
}

private enum CapsuleFixtureError: Error { case refused }
