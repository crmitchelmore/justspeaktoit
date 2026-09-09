#if os(iOS)
import Foundation

/// A primary snapshot plus an atomic sidecar of pending upserts. Neither file
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
    private var pending: [iOSHistoryItem] = []
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
    private func read(_ url: URL) throws -> [iOSHistoryItem] {
        let data: Data
        do {
            data = try storageIO.read(url)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && error.code == NSFileReadNoSuchFileError {
            return []
        }
        return try decoder.decode([iOSHistoryItem].self, from: data)
    }

    func load(visible: [iOSHistoryItem]) -> [iOSHistoryItem] {
        guard !isReady else { return visible }
        errorMessage = nil
        if !recoveryLoaded {
            do {
                pending = Self.merging(try read(recoveryURL), pending)
                recoveryLoaded = true
            } catch {
                report(error, store: "Recovery history")
            }
        }
        var merged = Self.merging(visible, pending)
        do {
            merged = Self.merging(try read(fileURL), merged)
            primaryLoaded = true
        } catch {
            primaryLoaded = false
            report(error, store: "Saved history")
        }
        recoveredIDs.formUnion(pending.map(\.id))
        guard primaryLoaded && recoveryLoaded else { return merged }
        if pending.isEmpty {
            isReady = true
        } else {
            // Commit before cleanup. If cleanup fails, replay remains idempotent;
            // destructive operations stay disabled until it succeeds.
            _ = save(merged)
        }
        return merged
    }

    func remember(_ item: iOSHistoryItem) {
        pending = Self.merging(pending, [item])
    }

    @discardableResult
    func save(_ items: [iOSHistoryItem]) -> Bool {
        if primaryLoaded && recoveryLoaded {
            do {
                try storageIO.write(encoder.encode(items), fileURL)
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
                pending.removeAll()
                isReady = true
                errorMessage = nil
                return true
            } catch {
                isReady = false
                errorMessage = "History could not be saved. Retry when storage is available."
            }
        }
        guard recoveryLoaded, !pending.isEmpty else {
            if !pending.isEmpty {
                errorMessage = "New history is only in memory. Keep the app open and retry saving."
            }
            return false
        }
        do {
            try storageIO.write(encoder.encode(pending), recoveryURL)
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

    private func report(_ error: Error, store: String) {
        if error is DecodingError {
            errorMessage = "\(store) could not be decoded. The original file has been preserved."
        } else {
            errorMessage = "\(store) is unavailable. Retry when storage is accessible."
        }
    }
}
#endif
