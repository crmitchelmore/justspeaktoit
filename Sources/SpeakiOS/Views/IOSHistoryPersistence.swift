#if os(iOS)
import Foundation
import CryptoKit

/// A primary snapshot plus an atomic sidecar of pending mutations. Neither file
/// may be replaced until it has been read successfully (or is positively absent).
@MainActor
final class IOSHistoryPersistence {
    struct StorageIO {
        var read: (URL) throws -> Data = { try Data(contentsOf: $0) }
        var write: (Data, URL) throws -> Void = { data, url in
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        var remove: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    }

    let fileURL: URL
    let recoveryURL: URL
    private let storageIO: StorageIO
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private struct Recovery: Codable {
        var items: [iOSHistoryItem]
        var deletedIDs: Set<UUID>
        var baseDigests: [String: String]?
    }

    private var pending: [UUID: iOSHistoryItem] = [:]
    private var pendingDeletedIDs: Set<UUID> = []
    private var recovery = Recovery(items: [], deletedIDs: [], baseDigests: nil)
    private var primaryItemDigests: [String: String] = [:]
    private var cleanupNeeded = false
    private var recoveryLoaded = false
    private var primaryLoaded = false
    private(set) var isReady = false
    private(set) var errorMessage: String?
    private(set) var recoveredIDs: Set<UUID> = []

    init(fileURL: URL, storageIO: StorageIO = StorageIO()) {
        self.fileURL = fileURL
        self.recoveryURL = fileURL.appendingPathExtension("recovery")
        self.storageIO = storageIO
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        decoder.dateDecodingStrategy = .iso8601
    }

    static func merging(_ original: [iOSHistoryItem], _ additions: [iOSHistoryItem]) -> [iOSHistoryItem] {
        var byID: [UUID: iOSHistoryItem] = [:]
        for item in original + additions {
            if let existing = byID[item.id], existing.updatedAt > item.updatedAt { continue }
            byID[item.id] = item
        }
        return byID.values.sorted {
            if $0.createdAt == $1.createdAt { return $0.id.uuidString < $1.id.uuidString }
            return $0.createdAt > $1.createdAt
        }
    }

    /// Failed reads never establish an empty store. In particular, fileExists
    /// cannot distinguish an absent file from an inaccessible one.
    private func readData(_ url: URL) throws -> Data? {
        do {
            return try storageIO.read(url)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && error.code == NSFileReadNoSuchFileError {
            return nil
        }
    }

    private func itemDigests(_ items: [iOSHistoryItem]) throws -> [String: String] {
        try Dictionary(items.map { item in
            let data = try encoder.encode(item)
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return (item.id.uuidString, hash)
        }, uniquingKeysWith: { _, latest in latest })
    }

    private func primaryMatchesRecoveryBase(_ id: UUID) -> Bool {
        guard let expected = recovery.baseDigests?[id.uuidString] else { return false }
        return expected == (primaryItemDigests[id.uuidString] ?? "absent")
    }

    func load(visible: [iOSHistoryItem]) -> [iOSHistoryItem] {
        guard !isReady else { return visible }
        errorMessage = nil
        loadRecoveryIfNeeded()
        var primary = visible
        do {
            let data = try readData(fileURL)
            primary = try data.map { try decoder.decode([iOSHistoryItem].self, from: $0) } ?? []
            primaryItemDigests = try itemDigests(primary)
            primaryLoaded = true
        } catch {
            primaryLoaded = false
            report(error, store: "Saved history")
        }
        // Compare each pending row with its original primary version. Unrelated
        // primary changes must not suppress an uncommitted same-second update.
        // A changed row in primary wins ties after merge committed but cleanup failed.
        let uncommitted = recovery.items.filter { primaryMatchesRecoveryBase($0.id) }
        let retained = recovery.items.filter { !primaryMatchesRecoveryBase($0.id) }
        var merged = Self.merging(Self.merging(retained, primary), uncommitted)
        merged.removeAll { recovery.deletedIDs.contains($0.id)
            && (!primaryLoaded || primaryMatchesRecoveryBase($0.id)) }
        merged = Self.merging(merged, Array(pending.values))
        merged.removeAll { pendingDeletedIDs.contains($0.id) }
        recoveredIDs.formUnion(recovery.items.map(\.id))
        recoveredIDs.formUnion(pending.keys)
        guard primaryLoaded && recoveryLoaded else { return merged }
        if pending.isEmpty && pendingDeletedIDs.isEmpty
            && recovery.items.isEmpty && recovery.deletedIDs.isEmpty && !cleanupNeeded {
            isReady = true
        } else {
            _ = save(merged)
        }
        return merged
    }

    private func loadRecoveryIfNeeded() {
        guard !recoveryLoaded else { return }
        do {
            if let data = try readData(recoveryURL) {
                if let legacy = try? decoder.decode([iOSHistoryItem].self, from: data) {
                    recovery = Recovery(items: legacy, deletedIDs: [], baseDigests: nil)
                } else {
                    recovery = try decoder.decode(Recovery.self, from: data)
                }
                cleanupNeeded = true
            }
            recoveryLoaded = true
        } catch {
            report(error, store: "Recovery history")
        }
    }

    func remember(_ item: iOSHistoryItem) {
        if let existing = pending[item.id], existing.updatedAt > item.updatedAt { return }
        pending[item.id] = item
        pendingDeletedIDs.remove(item.id)
        recovery.deletedIDs.remove(item.id)
    }

    func rememberDeletion(_ id: UUID) {
        pending.removeValue(forKey: id)
        recovery.items.removeAll { $0.id == id }
        pendingDeletedIDs.insert(id)
    }

    @discardableResult
    func save(_ items: [iOSHistoryItem]) -> Bool {
        if primaryLoaded && recoveryLoaded {
            do {
                try commitSnapshot(items)
                do {
                    try storageIO.remove(recoveryURL)
                } catch let error as NSError where error.domain == NSCocoaErrorDomain
                    && error.code == NSFileNoSuchFileError {
                    // No sidecar was needed.
                } catch {
                    isReady = false
                    errorMessage = "History saved; recovery cleanup needs a retry."
                    return true
                }
                cleanupNeeded = false
                isReady = true
                errorMessage = nil
                return true
            } catch {
                isReady = false
                errorMessage = "History could not be saved. Retry when storage is available."
            }
        }
        let hasPending = !pending.isEmpty || !pendingDeletedIDs.isEmpty
            || !recovery.items.isEmpty || !recovery.deletedIDs.isEmpty
        guard recoveryLoaded, hasPending else {
            if hasPending {
                errorMessage = "New history is only in memory. Keep the app open and retry saving."
            }
            return false
        }
        do {
            try storageIO.write(encoder.encode(recoveryPayload()), recoveryURL)
            cleanupNeeded = true
            // This is durable recovery, not a successfully loaded primary store.
            if primaryLoaded {
                errorMessage = "History changes are saved for recovery. Retry to restore history storage."
            }
            return true
        } catch {
            errorMessage = "New history is only in memory. Keep the app open and retry saving."
            return false
        }
    }

    private func recoveryPayload() -> Recovery {
        var byID = Dictionary(recovery.items.map { ($0.id, $0) }, uniquingKeysWith: {
            $0.updatedAt > $1.updatedAt ? $0 : $1
        })
        for (id, item) in pending where (byID[id]?.updatedAt ?? .distantPast) <= item.updatedAt {
            byID[id] = item
        }
        let deletedIDs = recovery.deletedIDs.union(pendingDeletedIDs)
        let recoverable = byID.values.filter { !deletedIDs.contains($0.id) }
        var bases = recovery.baseDigests ?? [:]
        // Fresh in-memory changes supersede any stale sidecar revision of the
        // same UUID, so their base is the currently loaded primary version.
        for id in Set(pending.keys).union(pendingDeletedIDs) {
            bases[id.uuidString] = primaryItemDigests[id.uuidString] ?? "absent"
        }
        for id in Set(recoverable.map(\.id)).union(deletedIDs) where bases[id.uuidString] == nil {
            bases[id.uuidString] = primaryItemDigests[id.uuidString] ?? "absent"
        }
        return Recovery(items: recoverable, deletedIDs: deletedIDs, baseDigests: bases)
    }

    private func commitSnapshot(_ items: [iOSHistoryItem]) throws {
        let changedIDs = Set(pending.keys).union(recovery.items.map(\.id))
        let changedDigests = try itemDigests(items.filter { changedIDs.contains($0.id) })
        let data = try encoder.encode(items)
        try storageIO.write(data, fileURL)
        let writtenIDs = Set(items.map { $0.id.uuidString })
        primaryItemDigests = primaryItemDigests.filter { writtenIDs.contains($0.key) }
        primaryItemDigests.merge(changedDigests, uniquingKeysWith: { _, latest in latest })
        // Clear only after the primary commit. A leftover sidecar is recognised
        // by its old per-entry base digests when the app restarts.
        pending.removeAll()
        pendingDeletedIDs.removeAll()
        recovery = Recovery(items: [], deletedIDs: [], baseDigests: nil)
        cleanupNeeded = true
    }

    private func report(_ error: Error, store: String) {
        if error is DecodingError {
            errorMessage = "\(store) could not be decoded. The original file has been preserved."
        } else {
            errorMessage = "\(store) is unavailable. Retry when storage is accessible."
        }
    }
}
#endif
