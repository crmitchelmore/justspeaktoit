import Foundation
import SpeakSync

/// What this device remembers about CloudKit sync between launches.
///
/// Nothing here is a credential: the web auth token and the API-key sync key
/// live in the platform credential store. Cursors and acknowledgements belong
/// to one iCloud user (`boundAccount`) and are forgotten when another signs in.
public struct DesktopCloudSyncState: Codable, Equatable, Sendable {
    /// One local History record's sync bookkeeping.
    public struct HistoryEntry: Codable, Equatable, Sendable {
        /// Fingerprint of the content CloudKit last confirmed, if any.
        public var acknowledged: String?
        /// Fingerprint of the content this device last saw locally.
        public var observed: String
        /// When the observed content last changed, in whole milliseconds, the
        /// CloudKit Date/Time precision, so a round trip is not an edit.
        public var updatedAt: Date
        /// Deleted on another device while this device keeps its own recording.
        /// Such a record is never uploaded again.
        public var deletedElsewhere: Bool

        public init(acknowledged: String?, observed: String, updatedAt: Date, deletedElsewhere: Bool = false) {
            self.acknowledged = acknowledged
            self.observed = observed
            self.updatedAt = updatedAt
            self.deletedElsewhere = deletedElsewhere
        }
    }

    /// One imported API key's bookkeeping. Values are never stored here.
    public struct ImportedKey: Codable, Equatable, Sendable {
        /// The newest remote revision already considered.
        public var lastRemoteUpdate: Date
        /// True while the saved credential is the imported value. Saving a key
        /// by hand clears it, so a later remote deletion leaves that key alone.
        public var isImportedValue: Bool

        public init(lastRemoteUpdate: Date, isImportedValue: Bool) {
            self.lastRemoteUpdate = lastRemoteUpdate
            self.isImportedValue = isImportedValue
        }
    }

    public var enabledFeatures: Set<CloudKitWebSyncFeature> = []
    public var boundAccount: String?
    /// The History change-feed cursor (an opaque web `syncToken`).
    public var historyCursor: Data?
    public var history: [UUID: HistoryEntry] = [:]
    public var importedKeys: [String: ImportedKey] = [:]
    public var lastSuccessfulSync: Date?

    public init() {}

    public var consent: CloudKitWebSyncConsent { CloudKitWebSyncConsent(enabledFeatures: enabledFeatures) }

    /// Forgets everything that belonged to the previously bound iCloud user.
    public mutating func forgetAccountData() {
        historyCursor = nil
        history = [:]
        importedKeys = [:]
        lastSuccessfulSync = nil
    }
}

/// File-backed sync state, written atomically after every change that a
/// crash must not lose (acknowledgements and the cursor).
public actor DesktopCloudSyncStateStore: SyncChangeTokenStore, CloudKitWebSyncAccountStore {
    public let url: URL
    private var state: DesktopCloudSyncState

    public init(url: URL) throws {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            state = try JSONDecoder().decode(DesktopCloudSyncState.self, from: Data(contentsOf: url))
        } else {
            state = DesktopCloudSyncState()
        }
    }

    public var current: DesktopCloudSyncState { state }

    /// Applies a change and saves it before returning.
    public func update<T>(_ change: (inout DesktopCloudSyncState) throws -> T) throws -> T {
        var updated = state
        let result = try change(&updated)
        if updated != state {
            try write(updated)
            state = updated
        }
        return result
    }

    private func write(_ state: DesktopCloudSyncState) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: url, options: .atomic)
    }

    // MARK: SyncChangeTokenStore

    public func loadChangeToken() async throws -> Data? { state.historyCursor }

    public func saveChangeToken(_ token: Data) async throws {
        try update { $0.historyCursor = token }
    }

    public func clearChangeToken() async throws {
        try update { $0.historyCursor = nil }
    }

    // MARK: CloudKitWebSyncAccountStore

    public func boundAccountRecordName() async throws -> String? { state.boundAccount }

    /// Binding a different user drops the previous user's acknowledgements,
    /// so this device's History uploads to the new account instead of being
    /// treated as already synced.
    public func bindAccount(recordName: String) async throws {
        try update { state in
            if state.boundAccount != recordName {
                state.forgetAccountData()
            }
            state.boundAccount = recordName
        }
    }
}
