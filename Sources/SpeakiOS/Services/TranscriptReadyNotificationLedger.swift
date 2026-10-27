#if os(iOS)
import Foundation

/// Device-local protected atomic claims. Unreadable/corrupt storage fails closed;
/// it is never replaced with an empty ledger that could repeat old alerts.
@MainActor
final class TranscriptReadyNotificationLedger {
    private struct Snapshot: Codable {
        var version = 1
        var claims: [UUID: Date] = [:]
    }

    private let url: URL
    private let write: (Data, URL, Data.WritingOptions) throws -> Void
    private let read: (URL) throws -> Data

    init(
        url: URL,
        read: @escaping (URL) throws -> Data = { try Data(contentsOf: $0) },
        write: @escaping (Data, URL, Data.WritingOptions) throws -> Void = { data, url, options in
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        try data.write(to: url, options: options)
        }
    ) {
        self.url = url
        self.read = read
        self.write = write
    }

    func claim(_ identifier: UUID, at date: Date) throws -> Bool {
        var snapshot = try self.load() ?? Snapshot()
        guard snapshot.claims[identifier] == nil else { return false }
        snapshot.claims[identifier] = date
        try self.write(
            JSONEncoder().encode(snapshot), self.url, [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
        return true
    }

    /// Only explicit local History deletion/clear retires claims. No retry expiry.
    func forget(_ identifiers: Set<UUID>) throws {
        guard var snapshot = try self.load() else { return }
        for identifier in identifiers { snapshot.claims.removeValue(forKey: identifier) }
        try self.write(
            JSONEncoder().encode(snapshot), self.url, [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }

    private func load() throws -> Snapshot? {
        let data: Data
        do {
            data = try self.read(self.url)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && error.code == NSFileReadNoSuchFileError {
            return nil
        }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        guard snapshot.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
        return snapshot
    }
}
#endif
