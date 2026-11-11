import Foundation

/// Active immutable snapshots, including operations outliving their UI deadline.
package final class DesktopComparisonStaging: @unchecked Sendable {
    package static let maximumBytes = 800_000_000
    package static let scratchBytes = 25_000_000
    private struct Reservation {
        var bytes: Int
        var owner = true
        var operations: Set<UUID> = []
    }
    private let lock = NSLock()
    private let limit: Int
    private var reservations: [UUID: Reservation] = [:]
    private var scratch: UUID?
    private var totalBytes = 0

    package init(limit: Int = maximumBytes) { self.limit = min(max(limit, 0), Self.maximumBytes) }

    package var byteCount: Int { lock.withLock { totalBytes } }

    package func reserve(id: UUID, bytes: Int) throws {
        try lock.withLock {
            let previous = reservations[id]?.bytes ?? 0
            guard bytes >= 0, bytes <= limit - (totalBytes - previous) else {
                throw DesktopComparisonError.message(
                    "Comparison staging exceeds its 800,000,000-byte audio and metadata safety budget."
                )
            }
            if reservations[id] == nil {
                reservations[id] = Reservation(bytes: bytes)
            } else {
                reservations[id]?.bytes = bytes
            }
            totalBytes += bytes - previous
        }
    }

    package func retain(id: UUID, operation: UUID) throws {
        try lock.withLock {
            guard reservations[id] != nil else {
                throw DesktopComparisonError.message("The comparison snapshot reservation is no longer available.")
            }
            reservations[id]?.operations.insert(operation)
        }
    }

    package func release(id: UUID, operation: UUID) {
        lock.withLock {
            reservations[id]?.operations.remove(operation)
            discardIfUnowned(id)
        }
    }

    package func releaseOwners(_ ids: Set<UUID>) {
        lock.withLock {
            for id in ids {
                reservations[id]?.owner = false
                discardIfUnowned(id)
            }
        }
    }

    package func beginScratch() throws -> UUID {
        try lock.withLock {
            guard scratch == nil else {
                throw DesktopComparisonError.message("A comparison import still owns the bounded scratch slot.")
            }
            let id = UUID()
            scratch = id
            return id
        }
    }

    package func endScratch(_ id: UUID) {
        lock.withLock { if scratch == id { scratch = nil } }
    }

    private func discardIfUnowned(_ id: UUID) {
        if let value = reservations[id], !value.owner, value.operations.isEmpty {
            totalBytes -= value.bytes
            reservations[id] = nil
        }
    }
}
