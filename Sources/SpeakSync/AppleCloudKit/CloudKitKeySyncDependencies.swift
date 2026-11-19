import CloudKit
import Foundation
import SpeakCore

struct KeySyncFetchResult {
    var records: [CKRecord]
    var deletedIDs: [CKRecord.ID]
    var serverChangeTokenData: Data?
    var moreComing: Bool
}

struct CloudKitKeySyncDatabase {
    let live: CKDatabase?
    /// Names the container in tests, where `live` is nil.
    var container: String?
}

struct PendingKeySyncMutation: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case update
        case deletion
    }

    let operationID: UUID
    let identifier: String
    let updatedAt: Date
    let kind: Kind
}

protocol CloudKitKeySyncSecretStoring: Sendable {
    func storeSecret(_ value: String, identifier: String) async throws
    func secret(identifier: String) async throws -> String
    func removeSecret(identifier: String) async throws
}

extension SecureStorage: CloudKitKeySyncSecretStoring {}

struct CloudKitKeySyncDependencies {
    let defaults: UserDefaults
    let notificationCenter: NotificationCenter
    let now: () -> Date
    let sleep: (UInt64) async throws -> Void
    let hasCloudKitEntitlement: () -> Bool
    let privateDatabase: () -> CloudKitKeySyncDatabase?
    let accountStatus: () async throws -> CKAccountStatus
    let accountRecordName: () async throws -> String
    let setupInfrastructure: ((CloudKitKeySyncDatabase) async throws -> Void)?
    let fetchRecord: ((CKRecord.ID, CloudKitKeySyncDatabase) async throws -> CKRecord?)?
    let saveRecord: ((CKRecord, CloudKitKeySyncDatabase) async throws -> CKRecord)?
    let fetchChanges: ((CloudKitKeySyncDatabase, Data?) async throws -> KeySyncFetchResult)?
    let makeFetchOperation: ((CloudKitKeySyncDatabase, Data?) -> any KeySyncFetchOperationRunning)?
    /// The pre-#1119 container this platform used, which the one-time key
    /// carry-over reads; `nil` where nothing moved.
    var legacyDatabase: (() -> CloudKitKeySyncDatabase?)?
    /// The iCloud user record name in the legacy container.
    var legacyAccountRecordName: (() async throws -> String)?

    static let live = CloudKitKeySyncDependencies(
        defaults: .standard,
        notificationCenter: .default,
        now: Date.init,
        sleep: { try await Task.sleep(nanoseconds: $0) },
        hasCloudKitEntitlement: { SyncConfiguration.hasCloudKitEntitlement },
        privateDatabase: {
            SyncConfiguration.privateDatabase.map { CloudKitKeySyncDatabase(live: $0) }
        },
        accountStatus: {
            guard let container = SyncConfiguration.container else {
                return .couldNotDetermine
            }
            return try await container.accountStatus()
        },
        accountRecordName: {
            guard let container = SyncConfiguration.container else {
                throw CloudKitKeySyncError.cloudUnavailable
            }
            return try await container.userRecordID().recordName
        },
        setupInfrastructure: nil,
        fetchRecord: nil,
        saveRecord: nil,
        fetchChanges: nil,
        makeFetchOperation: nil,
        legacyDatabase: {
            SyncConfiguration.legacyPrivateDatabase.map {
                CloudKitKeySyncDatabase(live: $0, container: SyncConfiguration.legacyContainerIdentifier)
            }
        },
        legacyAccountRecordName: {
            guard let container = SyncConfiguration.legacyContainer else {
                throw CloudKitKeySyncError.cloudUnavailable
            }
            return try await container.userRecordID().recordName
        }
    )
}
