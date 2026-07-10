import Foundation

/// A platform-agnostic transcription history entry for CloudKit and local transport sync.
public struct SyncableHistoryEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let rawTranscription: String?
    public let postProcessedText: String?
    public let model: String
    public let duration: TimeInterval
    public let wordCount: Int
    public let originPlatform: String
    public let updatedAt: Date
    public let originDeviceID: String

    private enum CodingKeys: String, CodingKey {
        case id, createdAt, rawTranscription, postProcessedText, model, duration, wordCount
        case originPlatform, updatedAt, originDeviceID
    }

    public init(
        id: UUID,
        createdAt: Date,
        rawTranscription: String?,
        postProcessedText: String?,
        model: String,
        duration: TimeInterval,
        wordCount: Int,
        originPlatform: String,
        updatedAt: Date,
        originDeviceID: String = DeviceIdentity.deviceId
    ) {
        self.id = id
        self.createdAt = createdAt
        self.rawTranscription = rawTranscription
        self.postProcessedText = postProcessedText
        self.model = model
        self.duration = duration
        self.wordCount = wordCount
        self.originPlatform = originPlatform
        self.updatedAt = updatedAt
        self.originDeviceID = originDeviceID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.createdAt = createdAt
        self.rawTranscription = try container.decodeIfPresent(String.self, forKey: .rawTranscription)
        self.postProcessedText = try container.decodeIfPresent(String.self, forKey: .postProcessedText)
        self.model = try container.decodeIfPresent(String.self, forKey: .model) ?? "unknown"
        self.duration = try container.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0
        self.wordCount = try container.decodeIfPresent(Int.self, forKey: .wordCount) ?? 0
        self.originPlatform = try container.decodeIfPresent(String.self, forKey: .originPlatform) ?? "unknown"
        self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        self.originDeviceID = try container.decodeIfPresent(String.self, forKey: .originDeviceID)
            ?? DeviceIdentity.deviceId
    }
}

/// Durable deletion marker used to converge history state across retrying sync channels.
public struct HistoryDeletionTombstone: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let deletedAt: Date
    public let originDeviceID: String

    public init(id: UUID, deletedAt: Date, originDeviceID: String = DeviceIdentity.deviceId) {
        self.id = id
        self.deletedAt = deletedAt
        self.originDeviceID = originDeviceID
    }
}

/// Snapshot exchanged over the local authenticated transport.
public struct HistorySyncSnapshot: Codable, Equatable, Sendable {
    public let entries: [SyncableHistoryEntry]
    public let tombstones: [HistoryDeletionTombstone]

    public init(entries: [SyncableHistoryEntry], tombstones: [HistoryDeletionTombstone]) {
        self.entries = entries
        self.tombstones = tombstones
    }
}

public struct AssembledHistoryBatch: Equatable, Sendable {
    public let requestID: UUID
    public let receivedBatchCount: Int
    public let snapshot: HistorySyncSnapshot
}

/// Buffers bounded history batches until a complete request can be applied atomically.
public struct HistoryBatchAccumulator {
    public static let maximumPendingRequests = 8
    public static let maximumBatchesPerRequest = 100

    private var batchesByRequest: [UUID: [Int: HistorySyncBatchMessage]] = [:]
    private var expectedBatchCounts: [UUID: Int] = [:]
    private var requestOrder: [UUID] = []

    public init() {}

    public mutating func append(_ batch: HistorySyncBatchMessage) -> AssembledHistoryBatch? {
        guard batch.isWithinBatchLimit,
              batch.batchIndex >= 0,
              batch.batchIndex < Self.maximumBatchesPerRequest
        else {
            return nil
        }

        if batchesByRequest[batch.requestID] == nil {
            evictOldestRequestIfNeeded()
            batchesByRequest[batch.requestID] = [:]
            requestOrder.append(batch.requestID)
        }
        batchesByRequest[batch.requestID]?[batch.batchIndex] = batch
        if batch.isLast {
            expectedBatchCounts[batch.requestID] = batch.batchIndex + 1
        }

        guard let expectedCount = expectedBatchCounts[batch.requestID],
              let batches = batchesByRequest[batch.requestID],
              batches.count == expectedCount,
              (0..<expectedCount).allSatisfy({ batches[$0] != nil })
        else {
            return nil
        }

        let ordered = (0..<expectedCount).compactMap { batches[$0] }
        let assembled = AssembledHistoryBatch(
            requestID: batch.requestID,
            receivedBatchCount: expectedCount,
            snapshot: HistorySyncSnapshot(
                entries: ordered.flatMap(\.entries),
                tombstones: ordered.flatMap(\.tombstones)
            )
        )
        removeRequest(batch.requestID)
        return assembled
    }

    public mutating func removeAll() {
        batchesByRequest.removeAll()
        expectedBatchCounts.removeAll()
        requestOrder.removeAll()
    }

    private mutating func evictOldestRequestIfNeeded() {
        guard requestOrder.count >= Self.maximumPendingRequests,
              let oldest = requestOrder.first
        else {
            return
        }
        removeRequest(oldest)
    }

    private mutating func removeRequest(_ requestID: UUID) {
        batchesByRequest.removeValue(forKey: requestID)
        expectedBatchCounts.removeValue(forKey: requestID)
        requestOrder.removeAll { $0 == requestID }
    }
}

/// Platform history bridge used by transport adapters without exposing native storage internals.
@MainActor
public protocol HistoryTransportDelegate: AnyObject {
    func historySnapshot(maxEntries: Int) -> HistorySyncSnapshot
    func applyHistoryBatch(entries: [SyncableHistoryEntry], tombstones: [HistoryDeletionTombstone]) async
}

public enum HistoryConflictResolver {
    public static func shouldReplace(existing: SyncableHistoryEntry, with candidate: SyncableHistoryEntry) -> Bool {
        if candidate.updatedAt != existing.updatedAt {
            return candidate.updatedAt > existing.updatedAt
        }
        return candidate.originDeviceID.lexicographicallyPrecedes(existing.originDeviceID) == false
            && candidate.originDeviceID != existing.originDeviceID
    }

    public static func newerTombstone(
        _ lhs: HistoryDeletionTombstone?,
        _ rhs: HistoryDeletionTombstone?
    ) -> HistoryDeletionTombstone? {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }
        if lhs.deletedAt != rhs.deletedAt {
            return lhs.deletedAt > rhs.deletedAt ? lhs : rhs
        }
        return lhs.originDeviceID.lexicographicallyPrecedes(rhs.originDeviceID) ? rhs : lhs
    }

    public static func tombstoneShadows(
        entry: SyncableHistoryEntry,
        tombstone: HistoryDeletionTombstone?
    ) -> Bool {
        guard let tombstone else { return false }
        return tombstone.deletedAt >= entry.updatedAt
    }

    public static func mergedEntries(
        existing: [SyncableHistoryEntry],
        incoming: [SyncableHistoryEntry],
        tombstones: [HistoryDeletionTombstone]
    ) -> [SyncableHistoryEntry] {
        var entriesByID: [UUID: SyncableHistoryEntry] = [:]
        for entry in existing + incoming {
            if let current = entriesByID[entry.id] {
                if shouldReplace(existing: current, with: entry) {
                    entriesByID[entry.id] = entry
                }
            } else {
                entriesByID[entry.id] = entry
            }
        }

        let tombstonesByID = mergedTombstones(existing: [], incoming: tombstones)
        return entriesByID.values
            .filter { !tombstoneShadows(entry: $0, tombstone: tombstonesByID[$0.id]) }
            .sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt {
                    return lhs.createdAt > rhs.createdAt
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }

    public static func mergedTombstones(
        existing: [HistoryDeletionTombstone],
        incoming: [HistoryDeletionTombstone]
    ) -> [UUID: HistoryDeletionTombstone] {
        var tombstonesByID: [UUID: HistoryDeletionTombstone] = [:]
        for tombstone in existing + incoming {
            tombstonesByID[tombstone.id] = newerTombstone(tombstonesByID[tombstone.id], tombstone)
        }
        return tombstonesByID
    }

    public static func visibleEntries(
        entries: [SyncableHistoryEntry],
        tombstones: [HistoryDeletionTombstone]
    ) -> [SyncableHistoryEntry] {
        mergedEntries(existing: entries, incoming: [], tombstones: tombstones)
    }
}

public final class HistoryTombstoneStore {
    public static let defaultRetention: TimeInterval = 90 * 24 * 60 * 60

    private let fileURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let retention: TimeInterval
    private let now: () -> Date

    public init(
        fileURL: URL,
        fileManager: FileManager = .default,
        retention: TimeInterval = HistoryTombstoneStore.defaultRetention,
        now: @escaping () -> Date = Date.init
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.retention = retention
        self.now = now
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder.dateDecodingStrategy = .iso8601
    }

    public func load() -> [HistoryDeletionTombstone] {
        guard fileManager.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let decoded = try? decoder.decode([HistoryDeletionTombstone].self, from: data)
        else {
            return []
        }
        return pruned(decoded)
    }

    public func save(_ tombstones: [HistoryDeletionTombstone]) throws {
        let prunedTombstones = pruned(tombstones)
        let parent = fileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parent.path) {
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        try encoder.encode(prunedTombstones).write(to: fileURL, options: [.atomic])
    }

    @discardableResult
    public func record(_ tombstone: HistoryDeletionTombstone) throws -> [HistoryDeletionTombstone] {
        let merged = Array(
            HistoryConflictResolver.mergedTombstones(existing: load(), incoming: [tombstone]).values
        )
        try save(merged)
        return pruned(merged)
    }

    public func pruned(_ tombstones: [HistoryDeletionTombstone]) -> [HistoryDeletionTombstone] {
        let cutoff = now().addingTimeInterval(-retention)
        let retained = tombstones.filter { $0.deletedAt >= cutoff }
        return Array(HistoryConflictResolver.mergedTombstones(existing: retained, incoming: []).values)
            .sorted { lhs, rhs in
                if lhs.deletedAt != rhs.deletedAt {
                    return lhs.deletedAt > rhs.deletedAt
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }
}
