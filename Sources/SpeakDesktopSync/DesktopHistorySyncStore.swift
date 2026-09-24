import Foundation
import SpeakCore
import SpeakDesktop
import SpeakSync

/// A History change this device applied from iCloud, for the host's UI.
public enum DesktopHistorySyncChange: Equatable, Sendable {
    /// A synced transcript was added or its text changed.
    case saved(UUID)
    /// A synced copy was removed because it was deleted on another device.
    case removed(UUID)
    /// Deleted on another device; this device keeps its own recording and audio.
    case keptAfterRemoteDeletion(UUID)
}

/// Projects desktop History records onto the shared nine-field
/// `SyncableHistoryEntry`, exactly as the Mac and iPhone project theirs.
public enum DesktopHistorySyncProjection {
    /// What Windows writes as `originPlatform` on its own recordings; the default.
    public static let originPlatform = "windows"
    /// What Linux writes as `originPlatform` on its own recordings.
    public static let linuxOriginPlatform = "linux"

    /// Only a finished transcript syncs. A recording still waiting for (or
    /// failing) transcription stays local until it has text.
    public static func isSyncable(_ record: DesktopRecordingStore.Record) -> Bool {
        record.result != nil || record.processedText != nil
    }

    /// `origin` names this device's platform; a synced copy keeps its own.
    public static func entry(
        for record: DesktopRecordingStore.Record,
        updatedAt: Date,
        origin: String = originPlatform
    ) -> SyncableHistoryEntry {
        let text = record.processedText ?? record.result?.text
        return SyncableHistoryEntry(
            id: record.id,
            createdAt: record.createdAt,
            rawTranscription: record.result?.text,
            postProcessedText: record.processedText,
            model: record.result?.modelIdentifier ?? record.modelIdentifier,
            duration: record.result?.duration ?? 0,
            // The Mac counts space-separated words the same way.
            wordCount: text?.split(separator: " ").count ?? 0,
            originPlatform: record.originPlatform ?? origin,
            updatedAt: updatedAt
        )
    }

    /// A stable, non-cryptographic fingerprint of everything the projection
    /// carries except `updatedAt`, used only to notice local edits.
    public static func fingerprint(_ entry: SyncableHistoryEntry) -> String {
        let parts: [String] = [
            entry.id.uuidString,
            String(millisecondsSince1970(entry.createdAt)),
            entry.rawTranscription.map { "r" + $0 } ?? "-",
            entry.postProcessedText.map { "p" + $0 } ?? "-",
            entry.model,
            String(entry.duration.bitPattern),
            String(entry.wordCount),
            entry.originPlatform
        ]
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in parts.joined(separator: "\u{1F}").utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 16)
    }

    /// CloudKit stores Date/Time in milliseconds.
    public static func roundedToMilliseconds(_ date: Date) -> Date {
        Date(timeIntervalSince1970: Double(millisecondsSince1970(date)) / 1000)
    }

    static func millisecondsSince1970(_ date: Date) -> Int64 {
        let value = (date.timeIntervalSince1970 * 1000).rounded()
        guard value.isFinite, abs(value) < 9.0e15 else { return 0 }
        return Int64(value)
    }
}

/// Connects desktop History to the shared History reconciliation.
///
/// Rules this adapter keeps:
/// - A transcript synced in is a record with no audio (`isSyncedCopy`); its
///   audio stays on the device that recorded it.
/// - A deletion from another device removes only such a synced copy. A
///   recording made here keeps its audio and metadata, is marked as deleted
///   elsewhere and is never uploaded again, so it cannot reappear on the Mac.
/// - A newer local edit is never overwritten by an older remote copy; the
///   shared conflict rule (the newer `updatedAt` wins) decides.
/// - Changes are reported to the host only after they are saved, so the UI
///   renders records that exist on disk.
public actor DesktopHistorySyncStore: HistorySyncStore {
    private let records: DesktopRecordingStore
    private let state: DesktopCloudSyncStateStore
    /// The `originPlatform` written on recordings made on this device.
    private let origin: String
    private let now: @Sendable () -> Date
    private let onChanges: @Sendable ([DesktopHistorySyncChange]) async -> Void
    /// Fingerprints of the content handed to the transport, by record.
    private var offered: [UUID: String] = [:]
    private var unreported: [DesktopHistorySyncChange] = []

    public init(
        records: DesktopRecordingStore,
        state: DesktopCloudSyncStateStore,
        origin: String = DesktopHistorySyncProjection.originPlatform,
        now: @escaping @Sendable () -> Date = { Date() },
        onChanges: @escaping @Sendable ([DesktopHistorySyncChange]) async -> Void = { _ in }
    ) {
        self.records = records
        self.state = state
        self.origin = origin
        self.now = now
        self.onChanges = onChanges
    }

    public func pendingEntries() async -> [SyncableHistoryEntry] {
        guard let all = try? await records.readableRecords() else { return [] }
        let syncable = all.filter(DesktopHistorySyncProjection.isSyncable)
        let stamp = DesktopHistorySyncProjection.roundedToMilliseconds(now())
        let observed: [UUID: DesktopCloudSyncState.HistoryEntry]
        do {
            observed = try await state.update { state in
                for record in syncable {
                    let fingerprint = DesktopHistorySyncProjection.fingerprint(
                        DesktopHistorySyncProjection.entry(for: record, updatedAt: stamp, origin: origin)
                    )
                    if var entry = state.history[record.id] {
                        guard entry.observed != fingerprint else { continue }
                        entry.observed = fingerprint
                        entry.updatedAt = max(stamp, entry.updatedAt)
                        state.history[record.id] = entry
                    } else {
                        // First sight: a record that predates sync keeps its
                        // creation time, so any existing remote copy wins.
                        state.history[record.id] = DesktopCloudSyncState.HistoryEntry(
                            acknowledged: nil,
                            observed: fingerprint,
                            updatedAt: DesktopHistorySyncProjection.roundedToMilliseconds(record.createdAt)
                        )
                    }
                }
                return state.history
            }
        } catch {
            return []
        }
        var pending: [SyncableHistoryEntry] = []
        for record in syncable {
            guard let entry = observed[record.id], !entry.deletedElsewhere,
                  entry.acknowledged != entry.observed else { continue }
            pending.append(DesktopHistorySyncProjection.entry(for: record, updatedAt: entry.updatedAt, origin: origin))
            offered[record.id] = entry.observed
        }
        return pending.sorted { $0.createdAt < $1.createdAt }
    }

    public func didReceiveRemoteEntry(_ entry: SyncableHistoryEntry) async {
        let current = await state.current.history[entry.id]
        if let current, current.updatedAt > entry.updatedAt, current.acknowledged != current.observed {
            // A newer local edit is waiting to upload; it wins.
            return
        }
        // CloudKit's copy replaces whatever this device offered for upload, so
        // a later acknowledgement must not mark the offered content as synced.
        offered[entry.id] = nil
        let existing = await records.existingRecord(id: entry.id)
        let record = Self.merge(entry, into: existing)
        do {
            try await records.save(record)
            let fingerprint = DesktopHistorySyncProjection.fingerprint(
                DesktopHistorySyncProjection.entry(for: record, updatedAt: entry.updatedAt, origin: origin)
            )
            try await state.update { state in
                state.history[entry.id] = DesktopCloudSyncState.HistoryEntry(
                    acknowledged: fingerprint,
                    observed: fingerprint,
                    updatedAt: DesktopHistorySyncProjection.roundedToMilliseconds(entry.updatedAt)
                )
            }
            unreported.append(.saved(entry.id))
        } catch {
            // Not saved: nothing is acknowledged, so the next pass replays it.
        }
    }

    public func didDeleteRemoteEntry(id: UUID) async {
        do {
            if try await records.removeSyncedCopy(id: id) {
                try await state.update { $0.history[id] = nil }
                unreported.append(.removed(id))
            } else {
                try await state.update { state in
                    if var entry = state.history[id] {
                        entry.deletedElsewhere = true
                        state.history[id] = entry
                    } else {
                        state.history[id] = DesktopCloudSyncState.HistoryEntry(
                            acknowledged: nil, observed: "", updatedAt: Date(timeIntervalSince1970: 0),
                            deletedElsewhere: true
                        )
                    }
                }
                unreported.append(.keptAfterRemoteDeletion(id))
            }
        } catch {
            // Unreadable: leave it exactly as it is.
        }
    }

    public func didAcknowledgeSyncedEntries(ids: Set<UUID>) async {
        let confirmed = ids.compactMap { id in offered[id].map { (id, $0) } }
        for (id, _) in confirmed { offered[id] = nil }
        try? await state.update { state in
            for (id, fingerprint) in confirmed {
                state.history[id]?.acknowledged = fingerprint
            }
        }
    }

    /// Reports the changes applied since the last report. Each was saved, with
    /// its sync state, by a step the pass fence admitted; this writes nothing
    /// account-bound, which is why the fence does not admit it. It can
    /// therefore run after the pass's session has ended, and a pass stopped
    /// before reaching it leaves its saved changes for the next one to report:
    /// either way the window only learns of records already on disk.
    public func persistRemoteChanges() async throws {
        guard !unreported.isEmpty else { return }
        let changes = unreported
        unreported.removeAll()
        await onChanges(changes)
    }

    /// Builds the local record for a remote entry. A recording made here keeps
    /// its audio, model and diagnostics; only the synced text changes.
    static func merge(
        _ entry: SyncableHistoryEntry,
        into existing: DesktopRecordingStore.Record?
    ) -> DesktopRecordingStore.Record {
        var record = existing ?? DesktopRecordingStore.Record(
            syncedID: entry.id,
            createdAt: entry.createdAt,
            modelIdentifier: entry.model,
            originPlatform: entry.originPlatform
        )
        if let raw = entry.rawTranscription {
            let previous = record.result
            record.result = TranscriptionResult(
                text: raw,
                segments: previous?.text == raw ? (previous?.segments ?? []) : [],
                confidence: previous?.confidence,
                duration: previous?.duration ?? entry.duration,
                modelIdentifier: previous?.modelIdentifier ?? entry.model,
                cost: previous?.cost,
                rawPayload: previous?.rawPayload,
                debugInfo: previous?.debugInfo
            )
        } else if record.isSyncedCopy {
            record.result = nil
        }
        record.processedText = entry.postProcessedText
        return record
    }
}
