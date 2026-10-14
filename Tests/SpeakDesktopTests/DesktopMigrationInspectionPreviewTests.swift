import Foundation
import SpeakCore
import XCTest
@testable import SpeakDesktop

final class DesktopMigrationInspectionPreviewTests: XCTestCase {
    private static let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private static let date = Date(timeIntervalSince1970: 1_704_067_200)
    private static let digests = LocalModelDigestProvider(name: "Synthetic digest for preview tests") {
        PreviewDigest()
    }

    func testIdenticalHistory_MergeAddsNothingAndPreservesSnapshots() async throws {
        let record = try history("Private synthetic text")
        let current = snapshot([record])
        let incoming = snapshot([record])
        let preview = try await make(current, incoming)
        XCTAssertEqual(preview.first?.changes?.existing, 1)
        XCTAssertEqual(preview.first?.changes?.added, 0)
        XCTAssertEqual(preview.first?.changes?.updated, 0)
        XCTAssertEqual(preview.first?.changes?.retained, 1)
        XCTAssertEqual(current.records[.history], [record])
        XCTAssertEqual(incoming.records[.history], [record])
    }

    func testDifferentHistory_PreviewsCanonicalVersionInsteadOfOverwrite() async throws {
        let current = snapshot([try history("Existing synthetic text")])
        let incoming = snapshot([try history("Imported synthetic text")])
        let preview = try await make(current, incoming)
        XCTAssertEqual(preview.first?.changes?.existing, 1)
        XCTAssertEqual(preview.first?.changes?.added, 1)
        XCTAssertEqual(preview.first?.changes?.updated, 0)
        XCTAssertEqual(preview.first?.changes?.retained, 2)
    }

    func testHistoryTextUpgrade_IsAnUpdateNotAnAdditionalVersion() async throws {
        var empty = DesktopRecordingStore.Record(
            id: Self.id, audioFilename: "", modelIdentifier: "synthetic/model", createdAt: Self.date
        )
        empty.processedText = nil
        let record = DataMigrationRecord(
            id: Self.id.uuidString, kind: "history", value: try DesktopMigrationHistory.value(empty), date: Self.date
        )
        let preview = try await make(snapshot([record]), snapshot([try history("Recovered text")]))
        XCTAssertEqual(preview.first?.changes?.added, 0)
        XCTAssertEqual(preview.first?.changes?.updated, 1)
        XCTAssertEqual(preview.first?.changes?.retained, 1)
    }

    func testMaterializedHistoryVersion_ReimportDoesNotPreviewAnotherCopy() async throws {
        let original = try history("Existing")
        let imported = try history("Imported")
        var variant = imported
        variant.id = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
        variant.value = try DataMigrationHistoryValue.value(variant.value, id: variant.id)
        let preview = try await make(snapshot([original, variant]), snapshot([imported]))
        XCTAssertEqual(preview.first?.changes?.existing, 2)
        XCTAssertEqual(preview.first?.changes?.added, 0)
        XCTAssertEqual(preview.first?.changes?.updated, 0)
        XCTAssertEqual(preview.first?.changes?.retained, 2)
    }

    func testHistoryAndAudioVersions_UseTheCanonicalPairedPlan() async throws {
        let current = DataMigrationSnapshot(
            manifest: .init(categories: [.history, .recordings], scopes: [:]),
            records: [.history: [try history("Existing")], .recordings: [try audio(String(repeating: "a", count: 64))]]
        )
        let incoming = DataMigrationSnapshot(
            manifest: .init(categories: [.history, .recordings], scopes: [:]),
            records: [.history: [try history("Imported")], .recordings: [try audio(String(repeating: "c", count: 64))]]
        )
        let preview = try await make(current, incoming)
        XCTAssertEqual(preview.map { $0.changes?.existing }, [1, 1])
        XCTAssertEqual(preview.map { $0.changes?.added }, [1, 1])
        XCTAssertEqual(preview.map { $0.changes?.updated }, [0, 0])
        XCTAssertEqual(preview.map { $0.changes?.retained }, [2, 2])
    }

    func testUnreadableIncomingCategory_IsNotAnEmptyMergeAndDoesNotCollectIt() async throws {
        let incoming = DataMigrationSnapshot(
            manifest: .init(categories: [.history, .recordings], scopes: [:]), records: [.history: []]
        )
        let current = snapshot([])
        let comparison = DesktopMigrationInspection.Comparison(digests: Self.digests) { categories in
            XCTAssertEqual(categories, [.history])
            return current
        }
        let preview = try await DesktopMigrationInspection.mergePreview(incoming, comparison: comparison)
        XCTAssertEqual(preview.map(\.category), [.history, .recordings])
        XCTAssertEqual(preview.first?.changes?.retained, 0)
        XCTAssertNil(preview.last?.changes)
    }

    func testNoReadableHistory_DoesNotCollectUnrelatedSettingsOrCredentials() async throws {
        let incoming = DataMigrationSnapshot(
            manifest: .init(categories: [.history, .settings, .credentials], scopes: [:]),
            records: [.credentials: [], .settings: []]
        )
        let comparison = DesktopMigrationInspection.Comparison(digests: Self.digests) { _ in
            XCTFail("Unreadable History must not cause unrelated data collection.")
            return incoming
        }
        let preview = try await DesktopMigrationInspection.mergePreview(incoming, comparison: comparison)
        XCTAssertEqual(preview.count, 1)
        XCTAssertEqual(preview.first?.category, .history)
        XCTAssertNil(preview.first?.changes)
    }

    func testMissingInvalidOrDamagedCurrentCategory_RefusesSuccessShapedCounts() async throws {
        let incoming = snapshot([try history("Imported")])
        var invalid = try history("Existing")
        invalid.id = UUID().uuidString
        let missing = DataMigrationSnapshot(manifest: .init(categories: [.history], scopes: [:]), records: [:])
        var damaged = snapshot([])
        damaged.notices = ["\(DataMigrationCategory.history.title): synthetic unavailable data."]
        for current in [missing, snapshot([invalid]), damaged] {
            await expectFailure { _ = try await self.make(current, incoming) }
        }
    }

    func testDuplicateCurrentOrIncomingIdentities_AreExplicitFailures() async throws {
        let record = try history("Existing")
        await expectFailure { _ = try await self.make(self.snapshot([record, record]), self.snapshot([record])) }
        await expectFailure { _ = try await self.make(self.snapshot([record]), self.snapshot([record, record])) }
    }

    func testCollectorFailure_PropagatesInsteadOfAssumingEmptyCurrentStore() async throws {
        let comparison = DesktopMigrationInspection.Comparison(digests: Self.digests) { _ in
            throw DataMigrationError.invalid("Synthetic current-store failure.")
        }
        await expectFailure(containing: "Synthetic current-store failure") {
            _ = try await DesktopMigrationInspection.mergePreview(self.snapshot([]), comparison: comparison)
        }
    }

    func testCancellationDuringCurrentCollection_DoesNotReturnPartialPreview() async throws {
        let incoming = snapshot([try history("Imported")])
        let current = snapshot([])
        let comparison = DesktopMigrationInspection.Comparison(digests: Self.digests) { _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return current
        }
        let cancelled = await Task.detached {
            do {
                _ = try await DesktopMigrationInspection.mergePreview(incoming, comparison: comparison)
                return false
            } catch is CancellationError {
                return true
            } catch {
                XCTFail("\(error)")
                return false
            }
        }.value
        XCTAssertTrue(cancelled)
    }

    private func history(_ text: String) throws -> DataMigrationRecord {
        var record = DesktopRecordingStore.Record(
            id: Self.id, audioFilename: "", modelIdentifier: "synthetic/model", createdAt: Self.date
        )
        record.processedText = text
        return .init(
            id: record.id.uuidString, kind: "history", value: try DesktopMigrationHistory.value(record),
            date: Self.date, revision: String(repeating: "c", count: 64)
        )
    }

    private func snapshot(_ records: [DataMigrationRecord]) -> DataMigrationSnapshot {
        .init(manifest: .init(categories: [.history], scopes: [:]), records: [.history: records])
    }

    private func audio(_ digest: String) throws -> DataMigrationRecord {
        var record = try history("Synthetic audio metadata")
        record.kind = "audio"
        record.value = try DataMigrationHistoryValue.value(record.value, audioOnly: true)
        record.digest = digest
        return record
    }

    private func make(
        _ current: DataMigrationSnapshot, _ incoming: DataMigrationSnapshot
    ) async throws -> [DesktopMigrationInspection.MergeCategory] {
        try await DesktopMigrationInspection.mergePreview(
            incoming, comparison: .init(digests: Self.digests, current: { _ in current })
        )
    }

    private func expectFailure(containing message: String? = nil, _ operation: () async throws -> Void) async {
        do {
            try await operation()
            XCTFail("Expected explicit preview failure.")
        } catch {
            if let message { XCTAssertTrue(error.localizedDescription.contains(message)) }
        }
    }
}

private final class PreviewDigest: LocalModelSHA256Hasher {
    func update(_ bytes: UnsafeRawBufferPointer) throws { try Task.checkCancellation() }
    func finish() throws -> String { String(repeating: "b", count: 64) }
}
