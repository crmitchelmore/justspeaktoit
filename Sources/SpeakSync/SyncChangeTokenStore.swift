import Foundation

/// Durable storage for one change feed's cursor.
///
/// A cursor belongs to the transport that produced it: the native adapter
/// stores an archived `CKServerChangeToken` and CloudKit Web Services returns
/// an opaque `syncToken` string. They are not interchangeable, so each client
/// keeps its own cursor for the same zone and never copies another's.
/// Requirements are asynchronous so a host can keep the cursor behind its own
/// actor or file store; a failed save leaves the previous cursor in place and
/// the next pass replays idempotently.
public protocol SyncChangeTokenStore: AnyObject {
    func loadChangeToken() async throws -> Data?
    func saveChangeToken(_ token: Data) async throws
    func clearChangeToken() async throws
}

/// The Apple engines' existing `UserDefaults` cursor keys.
final class UserDefaultsSyncChangeTokenStore: SyncChangeTokenStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults, key: String) {
        self.defaults = defaults
        self.key = key
    }

    func loadChangeToken() -> Data? {
        defaults.data(forKey: key)
    }

    func saveChangeToken(_ token: Data) {
        defaults.set(token, forKey: key)
    }

    func clearChangeToken() {
        defaults.removeObject(forKey: key)
    }
}
