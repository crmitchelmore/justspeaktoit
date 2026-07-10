// swiftlint:disable file_length
import Foundation
#if os(macOS)
import Security
#endif

// MARK: - Settings Sync using iCloud Key-Value Store

public enum SyncedSettingValue: Codable, Equatable, Sendable {
    case string(String)
    case bool(Bool)
    case double(Double)
    case stringArray([String])
    case null

    private enum CodingKeys: String, CodingKey { case type, value }
    private enum ValueType: String, Codable { case string, bool, double, stringArray, null }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(ValueType.self, forKey: .type)
        switch type {
        case .string:
            self = .string(try container.decode(String.self, forKey: .value))
        case .bool:
            self = .bool(try container.decode(Bool.self, forKey: .value))
        case .double:
            self = .double(try container.decode(Double.self, forKey: .value))
        case .stringArray:
            self = .stringArray(try container.decode([String].self, forKey: .value))
        case .null:
            self = .null
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .string(let value):
            try container.encode(ValueType.string, forKey: .type)
            try container.encode(value, forKey: .value)
        case .bool(let value):
            try container.encode(ValueType.bool, forKey: .type)
            try container.encode(value, forKey: .value)
        case .double(let value):
            try container.encode(ValueType.double, forKey: .type)
            try container.encode(value, forKey: .value)
        case .stringArray(let value):
            try container.encode(ValueType.stringArray, forKey: .type)
            try container.encode(value, forKey: .value)
        case .null:
            try container.encode(ValueType.null, forKey: .type)
        }
    }
}

public struct SyncedSettingRecord: Codable, Equatable, Sendable {
    public let key: SettingsSync.SyncKey
    public let value: SyncedSettingValue
    public let updatedAt: Date
    public let originDeviceID: String

    public init(
        key: SettingsSync.SyncKey,
        value: SyncedSettingValue,
        updatedAt: Date,
        originDeviceID: String = DeviceIdentity.deviceId
    ) {
        self.key = key
        self.value = value
        self.updatedAt = updatedAt
        self.originDeviceID = originDeviceID
    }
}

public enum SettingsConflictResolver {
    public static func shouldReplace(existing: SyncedSettingRecord, with candidate: SyncedSettingRecord) -> Bool {
        guard existing.key == candidate.key else { return false }
        if candidate.updatedAt != existing.updatedAt {
            return candidate.updatedAt > existing.updatedAt
        }
        return candidate.originDeviceID.lexicographicallyPrecedes(existing.originDeviceID) == false
            && candidate.originDeviceID != existing.originDeviceID
    }
}

public struct SettingsSyncSnapshot: Codable, Equatable, Sendable {
    public let records: [SyncedSettingRecord]

    public init(records: [SyncedSettingRecord]) {
        self.records = records
    }
}

public struct AssembledSettingsBatch: Equatable, Sendable {
    public let requestID: UUID
    public let receivedBatchCount: Int
    public let snapshot: SettingsSyncSnapshot
}

public struct SettingsBatchAccumulator: Sendable {
    public static let maximumPendingRequests = 8
    public static let maximumBatchesPerRequest = 100

    private var batchesByRequest: [UUID: [Int: SettingsSyncBatchMessage]] = [:]
    private var expectedBatchCounts: [UUID: Int] = [:]
    private var requestOrder: [UUID] = []

    public init() {}

    public mutating func append(_ batch: SettingsSyncBatchMessage) -> AssembledSettingsBatch? {
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
        let assembled = AssembledSettingsBatch(
            requestID: batch.requestID,
            receivedBatchCount: expectedCount,
            snapshot: SettingsSyncSnapshot(records: ordered.flatMap(\.records))
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
        else { return }
        removeRequest(oldest)
    }

    private mutating func removeRequest(_ requestID: UUID) {
        batchesByRequest.removeValue(forKey: requestID)
        expectedBatchCounts.removeValue(forKey: requestID)
        requestOrder.removeAll { $0 == requestID }
    }
}

@MainActor
public protocol SettingsTransportDelegate: AnyObject {
    func settingsSnapshot(maxRecords: Int) -> [SyncedSettingRecord]
    func applySettingsBatch(records: [SyncedSettingRecord]) async -> [SettingsSync.SyncKey]
}

protocol SettingsSyncBackingStore: AnyObject {
    func object(forKey defaultName: String) -> Any?
    func set(_ value: Any?, forKey defaultName: String)
    func removeObject(forKey defaultName: String)
    @discardableResult func synchronize() -> Bool
}

extension UserDefaults: SettingsSyncBackingStore {}
extension NSUbiquitousKeyValueStore: SettingsSyncBackingStore {}

// swiftlint:disable type_body_length
/// Syncs allowlisted, non-secret preferences across devices using iCloud KVS and local transport.
/// API keys and other secrets must stay in `SecureStorage` / iCloud Keychain only.
public final class SettingsSync: @unchecked Sendable {
    public static let shared = SettingsSync()

    public private(set) var isAvailable: Bool = false

    private static let recordPrefix = "sync.record."
    private static let legacyOriginDeviceID = "legacy"
    public static let changedKeysUserInfoKey = "changedKeys"

    private var store: SettingsSyncBackingStore?
    private let localStorage: SettingsSyncBackingStore
    private let notificationCenter: NotificationCenter
    private let now: () -> Date
    private let deviceID: () -> String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var recordsByKey: [SyncKey: SyncedSettingRecord] = [:]

    public enum SyncKey: String, CaseIterable, Codable, Sendable {
        case selectedModel = "sync.selectedModel"
        case autoStartRecording = "sync.autoStartRecording"
        case showConfidenceScore = "sync.showConfidenceScore"
        case hapticFeedback = "sync.hapticFeedback"
        case darkModePreference = "sync.darkModePreference"
        case lastSyncTimestamp = "sync.lastSyncTimestamp"
        case liveActivitiesEnabled = "sync.liveActivitiesEnabled"
        case hardwareTriggerDestination = "sync.hardwareTriggerDestination"
        case postProcessingEnabled = "sync.postProcessingEnabled"
        case postProcessingModel = "sync.postProcessingModel"
        case postProcessingPrompt = "sync.postProcessingPrompt"
        case autoPostProcess = "sync.autoPostProcess"
        case preferredLocale = "sync.preferredLocale"
        case appearance = "sync.appearance"
    }

    public static let didReceiveRemoteChangesNotification = Notification.Name("SettingsSyncDidReceiveRemoteChanges")
    public static let didChangeLocalRecordsNotification = Notification.Name("SettingsSyncDidChangeLocalRecords")

    private convenience init() {
        let ubiquitousStore: NSUbiquitousKeyValueStore?
        let available: Bool
        if FileManager.default.ubiquityIdentityToken != nil, Self.hasUbiquitousKVStoreEntitlement() {
            ubiquitousStore = .default
            available = true
        } else {
            ubiquitousStore = nil
            available = false
        }
        self.init(
            ubiquitousStore: ubiquitousStore,
            ubiquitousStoreObject: ubiquitousStore,
            localStorage: UserDefaults.standard,
            notificationCenter: .default,
            isUbiquitousStoreAvailable: available
        )
    }

    init(
        ubiquitousStore: SettingsSyncBackingStore?,
        ubiquitousStoreObject: Any? = nil,
        localStorage: SettingsSyncBackingStore,
        notificationCenter: NotificationCenter = .default,
        isUbiquitousStoreAvailable: Bool,
        now: @escaping () -> Date = Date.init,
        deviceID: @escaping () -> String = { DeviceIdentity.deviceId }
    ) {
        self.store = isUbiquitousStoreAvailable ? ubiquitousStore : nil
        self.localStorage = localStorage
        self.notificationCenter = notificationCenter
        self.now = now
        self.deviceID = deviceID
        self.isAvailable = isUbiquitousStoreAvailable && ubiquitousStore != nil
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601

        loadPersistedRecords()

        if let object = ubiquitousStoreObject, self.store != nil {
            notificationCenter.addObserver(
                self,
                selector: #selector(storeDidChange(_:)),
                name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                object: object
            )
            store?.synchronize()
        }
    }

    deinit {
        notificationCenter.removeObserver(self)
    }

    // MARK: - Public API

    @discardableResult
    public func set(_ value: SyncedSettingValue, forKey key: SyncKey) -> SyncedSettingRecord? {
        set(value, forKey: key, updatedAt: now(), originDeviceID: deviceID())
    }

    @discardableResult
    public func set(
        _ value: SyncedSettingValue,
        forKey key: SyncKey,
        updatedAt: Date,
        originDeviceID: String
    ) -> SyncedSettingRecord? {
        guard Self.isAllowed(record: SyncedSettingRecord(
            key: key,
            value: value,
            updatedAt: updatedAt,
            originDeviceID: originDeviceID
        )) else {
            return nil
        }
        if let existing = recordsByKey[key], existing.value == value {
            return existing
        }
        let record = SyncedSettingRecord(key: key, value: value, updatedAt: updatedAt, originDeviceID: originDeviceID)
        recordsByKey[key] = record
        persist(record)
        post(name: Self.didChangeLocalRecordsNotification, changedKeys: [key])
        return record
    }

    public func set(_ value: String?, forKey key: SyncKey) {
        set(value.map(SyncedSettingValue.string) ?? .null, forKey: key)
    }

    public func set(_ value: Bool, forKey key: SyncKey) {
        set(.bool(value), forKey: key)
    }

    public func set(_ value: Double, forKey key: SyncKey) {
        set(.double(value), forKey: key)
    }

    public func set(_ value: [String], forKey key: SyncKey) {
        set(.stringArray(value), forKey: key)
    }

    public func recordsSnapshot() -> [SyncedSettingRecord] {
        recordsByKey.values
            .filter(Self.isAllowed)
            .sorted { $0.key.rawValue < $1.key.rawValue }
    }

    public func record(forKey key: SyncKey) -> SyncedSettingRecord? {
        recordsByKey[key]
    }

    @discardableResult
    public func mergeIncomingRecords(
        _ records: [SyncedSettingRecord],
        notifyObservers: Bool = true
    ) -> [SyncKey] {
        let changed = apply(records: records, persistAccepted: true)
        if notifyObservers, !changed.isEmpty {
            post(name: Self.didReceiveRemoteChangesNotification, changedKeys: changed)
        }
        return changed
    }

    public func string(forKey key: SyncKey) -> String? {
        guard case .string(let value) = recordsByKey[key]?.value else { return nil }
        return value
    }

    public func bool(forKey key: SyncKey) -> Bool {
        guard case .bool(let value) = recordsByKey[key]?.value else { return false }
        return value
    }

    public func double(forKey key: SyncKey) -> Double? {
        guard case .double(let value) = recordsByKey[key]?.value else { return nil }
        return value
    }

    public func stringArray(forKey key: SyncKey) -> [String]? {
        guard case .stringArray(let value) = recordsByKey[key]?.value else { return nil }
        return value
    }

    public func synchronize() -> Bool {
        store?.synchronize() ?? true
    }

    public var lastSyncDate: Date? {
        recordsByKey.values.map(\.updatedAt).max()
    }

    public static func isAllowed(record: SyncedSettingRecord) -> Bool {
        guard record.key != .lastSyncTimestamp else { return false }
        let lowerKey = record.key.rawValue.lowercased()
        let forbiddenNames = ["apikey", "api_key", "token", "secret", "password"]
        guard !forbiddenNames.contains(where: { lowerKey.contains($0) }) else { return false }
        if record.key == .postProcessingPrompt {
            guard case .string(let prompt) = record.value else { return record.value == .null }
            return !containsCredentialLikeText(prompt)
        }
        return true
    }

    // MARK: - Private

    private func apply(records incoming: [SyncedSettingRecord], persistAccepted: Bool) -> [SyncKey] {
        var changed: [SyncKey] = []
        for record in incoming where Self.isAllowed(record: record) {
            if let existing = recordsByKey[record.key] {
                guard SettingsConflictResolver.shouldReplace(existing: existing, with: record) else { continue }
            }
            recordsByKey[record.key] = record
            if persistAccepted { persist(record) }
            changed.append(record.key)
        }
        return Array(Set(changed)).sorted { $0.rawValue < $1.rawValue }
    }

    private func loadPersistedRecords() {
        for key in SyncKey.allCases {
            let localRecord = decodeRecord(for: key, from: localStorage)
            let storeRecord = decodeRecord(for: key, from: store)
            let candidates = [localRecord, storeRecord].compactMap { $0 }
            if let resolved = candidates.max(by: { lhs, rhs in
                SettingsConflictResolver.shouldReplace(existing: lhs, with: rhs)
            }) {
                recordsByKey[key] = resolved
                if localRecord != resolved || (store != nil && storeRecord != resolved) {
                    persist(resolved)
                }
            } else if let legacy = legacyRecord(for: key) {
                recordsByKey[key] = legacy
                persist(legacy)
            }
        }
    }

    private func decodeRecord(for key: SyncKey, from backingStore: SettingsSyncBackingStore?) -> SyncedSettingRecord? {
        guard let object = backingStore?.object(forKey: Self.recordStoreKey(for: key)) else { return nil }
        let data: Data?
        if let raw = object as? Data {
            data = raw
        } else if let string = object as? String {
            data = Data(string.utf8)
        } else {
            data = nil
        }
        guard let data,
              let record = try? decoder.decode(SyncedSettingRecord.self, from: data),
              Self.isAllowed(record: record)
        else {
            return nil
        }
        return record
    }

    private func legacyRecord(for key: SyncKey) -> SyncedSettingRecord? {
        let object = store?.object(forKey: key.rawValue) ?? localStorage.object(forKey: key.rawValue)
        guard let object else { return nil }
        let value: SyncedSettingValue?
        switch object {
        case let string as String:
            value = .string(string)
        case let bool as Bool:
            value = .bool(bool)
        case let double as Double:
            value = .double(double)
        case let array as [String]:
            value = .stringArray(array)
        default:
            value = nil
        }
        guard let value else { return nil }
        let record = SyncedSettingRecord(
            key: key,
            value: value,
            updatedAt: .distantPast,
            originDeviceID: Self.legacyOriginDeviceID
        )
        return Self.isAllowed(record: record) ? record : nil
    }

    private func persist(_ record: SyncedSettingRecord) {
        guard let data = try? encoder.encode(record) else { return }
        localStorage.set(data, forKey: Self.recordStoreKey(for: record.key))
        store?.set(data, forKey: Self.recordStoreKey(for: record.key))
        store?.synchronize()
    }

    private func post(name: Notification.Name, changedKeys: [SyncKey]) {
        notificationCenter.post(
            name: name,
            object: self,
            userInfo: [Self.changedKeysUserInfoKey: changedKeys]
        )
    }

    @objc private func storeDidChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reason = userInfo[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
        else { return }
        let changedStoreKeys = userInfo[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]

        Task { @MainActor [weak self] in
            self?.processStoreChange(reason: reason, changedStoreKeys: changedStoreKeys)
        }
    }

    @MainActor
    private func processStoreChange(reason: Int, changedStoreKeys: [String]?) {
        switch reason {
        case NSUbiquitousKeyValueStoreServerChange,
             NSUbiquitousKeyValueStoreInitialSyncChange:
            let syncKeys = (changedStoreKeys?.compactMap(Self.syncKeyFromRecordStoreKey) ?? SyncKey.allCases)
            let records = syncKeys.compactMap { decodeRecord(for: $0, from: store) }
            _ = mergeIncomingRecords(records)
        case NSUbiquitousKeyValueStoreQuotaViolationChange:
            print("[SettingsSync] iCloud KV store quota exceeded")
        case NSUbiquitousKeyValueStoreAccountChange:
            print("[SettingsSync] iCloud account changed")
        default:
            break
        }
    }

    private static func recordStoreKey(for key: SyncKey) -> String {
        recordPrefix + key.rawValue
    }

    private static func syncKeyFromRecordStoreKey(_ key: String) -> SyncKey? {
        guard key.hasPrefix(recordPrefix) else { return nil }
        return SyncKey(rawValue: String(key.dropFirst(recordPrefix.count)))
    }

    private static func containsCredentialLikeText(_ value: String) -> Bool {
        let lower = value.lowercased()
        let forbidden = ["api key", "apikey", "api_key", "bearer ", "token", "secret", "password", "sk-", "pk-"]
        return forbidden.contains { lower.contains($0) }
    }

    private static func hasUbiquitousKVStoreEntitlement() -> Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil),
              SecTaskCopyValueForEntitlement(
                task,
                "com.apple.developer.ubiquity-kvstore-identifier" as CFString,
                nil
              ) != nil
        else {
            return false
        }
        return true
        #else
        return true
        #endif
    }
}
// swiftlint:enable type_body_length

// MARK: - QR Code Configuration Transfer

/// Enables transferring non-secret settings via QR code when iCloud sync is unavailable.
public struct ConfigTransferPayload: Codable {
    public var version: Int
    public var timestamp: Date
    public var secrets: [String: String]
    public var settings: [String: String]

    private enum CodingKeys: String, CodingKey {
        case version
        case timestamp
        case secrets
        case settings
    }

    public init(
        secrets: [String: String] = [:],
        settings: [String: String] = [:],
        version: Int = 2,
        timestamp: Date = Date()
    ) {
        self.version = version
        self.timestamp = timestamp
        self.secrets = secrets
        self.settings = settings
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        secrets = try container.decodeIfPresent([String: String].self, forKey: .secrets) ?? [:]
        settings = try container.decodeIfPresent([String: String].self, forKey: .settings) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(timestamp, forKey: .timestamp)
        if !secrets.isEmpty {
            try container.encode(secrets, forKey: .secrets)
        }
        try container.encode(settings, forKey: .settings)
    }
}

/// Handles settings-only encoding/decoding for QR transfer.
public final class ConfigTransferManager {
    public static let shared = ConfigTransferManager()
    private static let supportedSettingKeys: Set<String> = ["selectedModel"]

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    /// Generates a settings-only payload string for QR code generation.
    public func generatePayload(settings: [String: String]) throws -> String {
        try generatePayload(secrets: [:], settings: settings)
    }

    /// Generates a settings-only payload string for QR code generation.
    /// Non-empty secrets are rejected because secure storage/iCloud Keychain are canonical for API keys.
    public func generatePayload(secrets: [String: String], settings: [String: String]) throws -> String {
        guard secrets.isEmpty else {
            throw ConfigTransferError.secretTransferUnsupported
        }

        let unsupportedKeys = Self.unsupportedSettingKeys(in: settings)
        guard unsupportedKeys.isEmpty else {
            throw ConfigTransferError.unsupportedSettings(unsupportedKeys)
        }

        let payload = ConfigTransferPayload(settings: settings)
        let jsonData = try encoder.encode(payload)
        return jsonData.base64EncodedString()
    }

    /// Decodes a payload string from QR code scan.
    public func decodePayload(_ encoded: String) throws -> ConfigTransferPayload {
        guard let data = Data(base64Encoded: encoded) else {
            throw ConfigTransferError.invalidFormat
        }

        if let payload = try? decoder.decode(ConfigTransferPayload.self, from: data) {
            return try validatedCurrentPayload(payload)
        }

        let legacyData = deobfuscate(data: data)
        if let payload = try? decoder.decode(ConfigTransferPayload.self, from: legacyData) {
            return try validatedLegacyPayload(payload)
        }

        throw ConfigTransferError.decodingFailed
    }

    /// Validates that a payload is recent (within 10 minutes) to prevent replay.
    public func validatePayloadFreshness(_ payload: ConfigTransferPayload, maxAge: TimeInterval = 600) -> Bool {
        abs(payload.timestamp.timeIntervalSinceNow) < maxAge
    }

    private static func unsupportedSettingKeys(in settings: [String: String]) -> [String] {
        settings.keys.filter { !supportedSettingKeys.contains($0) }.sorted()
    }

    // MARK: - Legacy XOR Decode

    private let obfuscationKey: [UInt8] = [0x53, 0x70, 0x65, 0x61, 0x6B, 0x21]

    private func xor(data: Data) -> Data {
        var result = Data(count: data.count)
        for (index, byte) in data.enumerated() {
            result[index] = byte ^ obfuscationKey[index % obfuscationKey.count]
        }
        return result
    }

    private func deobfuscate(data: Data) -> Data {
        // XOR is its own inverse
        xor(data: data)
    }

    private func validatedCurrentPayload(_ payload: ConfigTransferPayload) throws -> ConfigTransferPayload {
        guard payload.version == 2 else {
            throw ConfigTransferError.unsupportedVersion(payload.version)
        }

        guard payload.secrets.isEmpty else {
            throw ConfigTransferError.secretTransferUnsupported
        }

        let unsupportedKeys = Self.unsupportedSettingKeys(in: payload.settings)
        guard unsupportedKeys.isEmpty else {
            throw ConfigTransferError.unsupportedSettings(unsupportedKeys)
        }

        return payload
    }

    private func validatedLegacyPayload(_ payload: ConfigTransferPayload) throws -> ConfigTransferPayload {
        guard payload.version == 1 else {
            throw ConfigTransferError.unsupportedVersion(payload.version)
        }

        guard payload.secrets.isEmpty else {
            throw ConfigTransferError.insecureLegacyPayload
        }

        let unsupportedKeys = Self.unsupportedSettingKeys(in: payload.settings)
        guard unsupportedKeys.isEmpty else {
            throw ConfigTransferError.unsupportedSettings(unsupportedKeys)
        }

        return payload
    }
}

public enum ConfigTransferError: LocalizedError {
    case invalidFormat
    case payloadExpired
    case decodingFailed
    case secretTransferUnsupported
    case insecureLegacyPayload
    case unsupportedSettings([String])
    case unsupportedVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidFormat:
            return "Invalid QR code format. Please scan a valid Speak configuration code."
        case .payloadExpired:
            return "This configuration code has expired. Please generate a new one."
        case .decodingFailed:
            return "Failed to decode configuration. The code may be corrupted."
        case .secretTransferUnsupported:
            return """
            QR transfer only supports non-secret settings. Enter API keys manually, or sync them with \
            iCloud Keychain.
            """
        case .insecureLegacyPayload:
            return """
            This older QR code contains API keys and cannot be imported. Generate a new settings-only code, \
            enter API keys manually, or sync them with iCloud Keychain.
            """
        case .unsupportedSettings(let keys):
            return "This configuration code contains unsupported settings: \(keys.joined(separator: ", "))."
        case .unsupportedVersion(let version):
            return "This configuration code uses unsupported version \(version). Please generate a new code."
        }
    }
}

// MARK: - Sync Availability

/// The cross-device sync backend selected by runtime auto-detection.
public enum SyncBackend: String, CaseIterable, Sendable {
    /// iCloud settings/history sync is available and preferred.
    case iCloud
    /// Bonjour local-network transport is available as the fallback path.
    case transport
    /// No cross-device backend is currently available; data remains local.
    case localOnly

    public var displayName: String {
        switch self {
        case .iCloud:
            return "iCloud"
        case .transport:
            return "Bonjour Transport"
        case .localOnly:
            return "Local Only"
        }
    }
}

/// Runtime cross-device sync capability summary for UI and app logic.
public struct SyncAvailability: Equatable, Sendable {
    public let iCloudKVStoreAvailable: Bool
    public let iCloudCloudKitAvailable: Bool
    public let transportAvailable: Bool
    public let distributionChannel: DistributionChannel

    public init(
        iCloudKVStoreAvailable: Bool = false,
        iCloudCloudKitAvailable: Bool = false,
        transportAvailable: Bool = false,
        distributionChannel: DistributionChannel = .current
    ) {
        self.iCloudKVStoreAvailable = iCloudKVStoreAvailable
        self.iCloudCloudKitAvailable = iCloudCloudKitAvailable
        self.transportAvailable = transportAvailable
        self.distributionChannel = distributionChannel
    }

    /// Whether any iCloud sync backend is currently usable.
    public var iCloudAvailable: Bool {
        iCloudKVStoreAvailable || iCloudCloudKitAvailable
    }

    /// Prefer iCloud when any iCloud sync path is available, otherwise fall back
    /// to the canonical Bonjour transport helper, then local-only storage.
    public var preferredBackend: SyncBackend {
        if iCloudAvailable {
            return .iCloud
        }
        if transportAvailable {
            return .transport
        }
        return .localOnly
    }

    /// Checks current sync availability. CloudKit account availability is owned
    /// by SpeakSync, so callers pass the latest `HistorySyncEngine` state.
    public static func current(
        iCloudCloudKitAvailable: Bool = false,
        transportAvailable: Bool = false
    ) -> SyncAvailability {
        let sync = SettingsSync.shared

        return SyncAvailability(
            iCloudKVStoreAvailable: sync.isAvailable,
            iCloudCloudKitAvailable: iCloudCloudKitAvailable,
            transportAvailable: transportAvailable,
            distributionChannel: .current
        )
    }

    /// Build support only. Runtime UI must pass actual discovery/connection state.
    @available(*, deprecated, message: "Pass actual runtime transport state to current(transportAvailable:)")
    public static var currentTransportAvailable: Bool {
        DistributionChannel.current.supportsLocalNetworkTransport
    }
}

// MARK: - Sync Status

/// Represents the current sync status across platforms.
public struct SyncStatus: Equatable, Sendable {
    public let iCloudKeychainAvailable: Bool
    public let iCloudKVStoreAvailable: Bool
    public let iCloudCloudKitAvailable: Bool
    public let transportAvailable: Bool
    public let lastSyncDate: Date?
    public let pendingChanges: Bool
    public let availability: SyncAvailability

    public var preferredBackend: SyncBackend {
        availability.preferredBackend
    }

    public init(
        iCloudKeychainAvailable: Bool = false,
        iCloudKVStoreAvailable: Bool = false,
        iCloudCloudKitAvailable: Bool = false,
        transportAvailable: Bool = false,
        lastSyncDate: Date? = nil,
        pendingChanges: Bool = false
    ) {
        self.iCloudKeychainAvailable = iCloudKeychainAvailable
        self.iCloudKVStoreAvailable = iCloudKVStoreAvailable
        self.iCloudCloudKitAvailable = iCloudCloudKitAvailable
        self.transportAvailable = transportAvailable
        self.lastSyncDate = lastSyncDate
        self.pendingChanges = pendingChanges
        self.availability = SyncAvailability(
            iCloudKVStoreAvailable: iCloudKVStoreAvailable,
            iCloudCloudKitAvailable: iCloudCloudKitAvailable,
            transportAvailable: transportAvailable
        )
    }

    /// Checks current sync availability
    public static func current(
        iCloudCloudKitAvailable: Bool = false,
        transportAvailable: Bool = false,
        iCloudKeychainAvailable: Bool = false
    ) -> SyncStatus {
        let sync = SettingsSync.shared
        let availability = SyncAvailability.current(
            iCloudCloudKitAvailable: iCloudCloudKitAvailable,
            transportAvailable: transportAvailable
        )

        return SyncStatus(
            iCloudKeychainAvailable: iCloudKeychainAvailable,
            iCloudKVStoreAvailable: availability.iCloudKVStoreAvailable,
            iCloudCloudKitAvailable: availability.iCloudCloudKitAvailable,
            transportAvailable: availability.transportAvailable,
            lastSyncDate: sync.lastSyncDate,
            pendingChanges: false
        )
    }
}
