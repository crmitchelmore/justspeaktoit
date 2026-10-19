import Foundation
import SpeakCore

extension DesktopMigrationRestore {
    struct HistoryWrite: Sendable {
        /// The planned archive record; a variant still carries its source value until materialised.
        let record: DataMigrationRecord
        let id: UUID
        let replacing: Bool
    }

    struct Computed: Sendable {
        var changes: [DataMigrationCategory: Changes] = [:]
        var skipped: [String] = []
        var history: [HistoryWrite] = []
        /// Nil leaves profiles.json untouched.
        var profiles: [DataMigrationRecord]?
    }

    static func plannedModes(
        _ incoming: DataMigrationSnapshot, choice: Choice
    ) -> [DataMigrationCategory: DataMigrationMode] {
        var modes: [DataMigrationCategory: DataMigrationMode] = [:]
        // Absent or unreadable categories are never planned, so they cannot clear existing data.
        for category in applied where incoming.manifest.categories.contains(category)
            && incoming.records[category] != nil {
            modes[category] = category == .profiles && choice == .replace ? .replace : .merge
        }
        return modes
    }

    static func baselineSnapshot(_ baseline: Baseline) -> DataMigrationSnapshot {
        DataMigrationSnapshot(
            manifest: .init(categories: [.history, .profiles], scopes: [:]),
            records: [.history: baseline.history, .profiles: baseline.profiles]
        )
    }

    static func currentBaseline(_ targets: Targets) async throws -> Baseline {
        let history = try await targets.history.migrationSnapshot(categories: [.history], digests: targets.digests)
        let source: DesktopOwnedAppDataFileReader.StrictSnapshot
        let profiles: [DataMigrationRecord]
        do {
            source = try DesktopOwnedAppDataFileReader.readStrict(
                DesktopDictationProfileStore.filename,
                appDirectory: targets.profiles.fileURL.deletingLastPathComponent(),
                maximumBytes: DataMigrationArchivePolicy.maximumJSONBytes
            )
            profiles = try source.data.map {
                try DataMigrationProfileCatalog.records(
                    data: $0, digest: targets.digests.sha256(of:), checkCancellation: { try Task.checkCancellation() }
                )
            } ?? []
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DataMigrationError.invalid(
                "This device's app profiles could not be read, so nothing was restored. "
                    + "Open App profiles to recover them first. \(error.localizedDescription)"
            )
        }
        return Baseline(history: history.records[.history] ?? [], profiles: profiles, profileDocument: source.data)
    }

    static func compute(
        _ incoming: DataMigrationSnapshot, baseline: Baseline, choice: Choice,
        guards: DesktopRecordingStore.MigrationRestoreGuards, digests: LocalModelDigestProvider
    ) throws -> Computed {
        let modes = plannedModes(incoming, choice: choice)
        let planned = try DesktopMigrationPlanner.plan(
            current: baselineSnapshot(baseline), incoming: incoming, modes: modes, useImported: [], digests: digests
        )
        var result = Computed()
        if modes[.history] != nil {
            try computeHistory(planned.records[.history] ?? [], baseline: baseline, guards: guards, into: &result)
        }
        if modes[.profiles] != nil {
            computeProfiles(planned.records[.profiles] ?? [], baseline: baseline, into: &result)
        }
        try Task.checkCancellation()
        return result
    }

    private static func computeHistory(
        _ planned: [DataMigrationRecord], baseline: Baseline,
        guards: DesktopRecordingStore.MigrationRestoreGuards, into result: inout Computed
    ) throws {
        let current = Dictionary(baseline.history.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<UUID>()
        var added = 0
        var updated = 0
        for record in planned {
            try Task.checkCancellation()
            let old = current[record.identity]
            if let old, old == record { continue }
            guard let id = UUID(uuidString: record.id), seen.insert(id).inserted else {
                result.skipped.append("History: an item with an unusable identifier was not imported.")
                continue
            }
            if old != nil {
                // A copy synced from another device keeps that device's version.
                guard !guards.synced.contains(id) else {
                    result.skipped.append("History: an item synced from another device was kept unchanged.")
                    continue
                }
                updated += 1
                result.history.append(.init(record: record, id: id, replacing: true))
            } else if guards.deleted.contains(id) {
                result.skipped.append("History: an item deleted on this device was not restored.")
            } else if guards.existing.contains(id) {
                result.skipped.append("History: an item already on this device was kept unchanged.")
            } else {
                added += 1
                result.history.append(.init(record: record, id: id, replacing: false))
            }
        }
        result.changes[.history] = Changes(
            existing: baseline.history.count, added: added, updated: updated, removed: 0,
            retained: baseline.history.count + added, reordered: false
        )
    }

    private static func computeProfiles(
        _ planned: [DataMigrationRecord], baseline: Baseline, into result: inout Computed
    ) {
        let before = Dictionary(
            baseline.profiles.map { ($0.identity, $0.value) }, uniquingKeysWith: { first, _ in first }
        )
        let after = Set(planned.map(\.identity))
        let added = planned.filter { before[$0.identity] == nil }.count
        let updated = planned.filter { record in before[record.identity].map { $0 != record.value } ?? false }.count
        let removed = baseline.profiles.filter { !after.contains($0.identity) }.count
        let unchangedValues = planned.map(\.value) == baseline.profiles.map(\.value)
        let reordered = added == 0 && updated == 0 && removed == 0 && !unchangedValues
        result.changes[.profiles] = Changes(
            existing: baseline.profiles.count, added: added, updated: updated, removed: removed,
            retained: planned.count, reordered: reordered
        )
        if !unchangedValues { result.profiles = planned }
    }

    /// Encodes planned profile values exactly as stored, preserving members the runtime cannot decode.
    static func profileDocument(_ records: [DataMigrationRecord]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(records.map(\.value))
        _ = try DictationProfile.decodeList(data)
        guard UInt64(data.count) <= DataMigrationArchivePolicy.maximumJSONBytes else {
            throw DataMigrationError.invalid("Restored app profiles exceed the supported size.")
        }
        return data
    }

    /// Converts a planned History record to a native record. The archive ID is
    /// materialised first so a conflict variant validates under its new identity.
    static func nativeHistory(
        _ write: HistoryWrite, existing: DesktopRecordingStore.Record?
    ) throws -> DesktopRecordingStore.Record {
        let value = try DataMigrationHistoryValue.value(write.record.value, id: write.record.id)
        var materialised = write.record
        materialised.value = value
        var native = try DesktopMigrationHistory.record(
            materialised, category: .history, audioFilename: existing?.audioFilename ?? ""
        )
        guard native.id == write.id else {
            throw DataMigrationError.invalid("History: a restored item changed identity.")
        }
        native.localAudio = existing?.localAudio
        // Never mark a restored item as a synced copy: removeSyncedCopy may delete those.
        native.originPlatform = nil
        return native
    }
}
