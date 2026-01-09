import Foundation

// MARK: - Settings Sync using iCloud Key-Value Store

/// Syncs non-secret preferences across devices using iCloud Key-Value Store.
/// For secrets/API keys, use SecureStorage with synchronizable=true.
/// 
/// NOTE: iCloud sync requires an Apple Developer subscription with iCloud entitlement.
/// Without it, this class fails gracefully - all operations become no-ops and
/// availability checks return false. Local settings still work via UserDefaults fallback.
public final class SettingsSync: @unchecked Sendable {
    public static let shared = SettingsSync()
    
    /// Whether iCloud KV store is available (requires Apple Developer subscription)
    public private(set) var isAvailable: Bool = false
    
    private var store: NSUbiquitousKeyValueStore?
    private let localStorage = UserDefaults.standard
    private let notificationCenter: NotificationCenter
    
    /// Keys that should be synced
    public enum SyncKey: String, CaseIterable {
        case selectedModel = "sync.selectedModel"
        case autoStartRecording = "sync.autoStartRecording"
        case showConfidenceScore = "sync.showConfidenceScore"
        case hapticFeedback = "sync.hapticFeedback"
        case darkModePreference = "sync.darkModePreference"
        case lastSyncTimestamp = "sync.lastSyncTimestamp"
    }
    
    /// Notification posted when remote settings change
    public static let didReceiveRemoteChangesNotification = Notification.Name("SettingsSyncDidReceiveRemoteChanges")
    
    private init() {
        self.notificationCenter = NotificationCenter.default
        
        // Check if iCloud is available before trying to use it
        if FileManager.default.ubiquityIdentityToken != nil {
            self.store = NSUbiquitousKeyValueStore.default
            self.isAvailable = true
            
            // Listen for remote changes
            notificationCenter.addObserver(
                self,
                selector: #selector(storeDidChange(_:)),
                name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                object: store
            )
            
            // Start syncing
            store?.synchronize()
        } else {
            // iCloud not available - use local storage fallback
            self.store = nil
            self.isAvailable = false
            print("[SettingsSync] iCloud not available - using local storage only")
        }
    }
    
    deinit {
        notificationCenter.removeObserver(self)
    }
    
    // MARK: - Public API
    
    /// Stores a string value for the given key (falls back to local storage if iCloud unavailable)
    public func set(_ value: String?, forKey key: SyncKey) {
        if let store = store {
            store.set(value, forKey: key.rawValue)
            store.set(Date().timeIntervalSince1970, forKey: SyncKey.lastSyncTimestamp.rawValue)
            store.synchronize()
        } else {
            // Fallback to local storage
            localStorage.set(value, forKey: key.rawValue)
        }
    }
    
    /// Stores a boolean value for the given key (falls back to local storage if iCloud unavailable)
    public func set(_ value: Bool, forKey key: SyncKey) {
        if let store = store {
            store.set(value, forKey: key.rawValue)
            store.set(Date().timeIntervalSince1970, forKey: SyncKey.lastSyncTimestamp.rawValue)
            store.synchronize()
        } else {
            localStorage.set(value, forKey: key.rawValue)
        }
    }
    
    /// Retrieves a string value for the given key
    public func string(forKey key: SyncKey) -> String? {
        if let store = store {
            return store.string(forKey: key.rawValue)
        } else {
            return localStorage.string(forKey: key.rawValue)
        }
    }
    
    /// Retrieves a boolean value for the given key
    public func bool(forKey key: SyncKey) -> Bool {
        if let store = store {
            return store.bool(forKey: key.rawValue)
        } else {
            return localStorage.bool(forKey: key.rawValue)
        }
    }
    
    /// Forces a sync with iCloud (no-op if iCloud unavailable)
    public func synchronize() -> Bool {
        store?.synchronize() ?? true
    }
    
    /// Gets the timestamp of the last sync (nil if iCloud unavailable)
    public var lastSyncDate: Date? {
        guard let store = store else { return nil }
        let timestamp = store.double(forKey: SyncKey.lastSyncTimestamp.rawValue)
        guard timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }
    
    // MARK: - Private
    
    @objc private func storeDidChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reason = userInfo[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
        else { return }
        
        switch reason {
        case NSUbiquitousKeyValueStoreServerChange,
             NSUbiquitousKeyValueStoreInitialSyncChange:
            // Post notification for UI to update
            notificationCenter.post(name: Self.didReceiveRemoteChangesNotification, object: self)
        case NSUbiquitousKeyValueStoreQuotaViolationChange:
            print("[SettingsSync] iCloud KV store quota exceeded")
        case NSUbiquitousKeyValueStoreAccountChange:
            print("[SettingsSync] iCloud account changed")
        default:
            break
        }
    }
}

// MARK: - QR Code Configuration Transfer

/// Enables transferring API keys and configuration via QR code when iCloud sync is unavailable.
public struct ConfigTransferPayload: Codable {
    public var version: Int = 1
    public var timestamp: Date
    public var secrets: [String: String]
    public var settings: [String: String]
    
    public init(secrets: [String: String] = [:], settings: [String: String] = [:]) {
        self.timestamp = Date()
        self.secrets = secrets
        self.settings = settings
    }
}

/// Handles encoding/decoding of configuration for QR transfer.
public final class ConfigTransferManager {
    public static let shared = ConfigTransferManager()
    
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    
    private init() {
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }
    
    /// Generates an encrypted payload string for QR code generation.
    /// The payload is base64-encoded JSON with optional encryption.
    public func generatePayload(secrets: [String: String], settings: [String: String]) throws -> String {
        let payload = ConfigTransferPayload(secrets: secrets, settings: settings)
        let jsonData = try encoder.encode(payload)
        
        // Simple obfuscation: XOR with a key then base64
        // In production, use proper encryption with a user-provided PIN
        let obfuscated = obfuscate(data: jsonData)
        return obfuscated.base64EncodedString()
    }
    
    /// Decodes a payload string from QR code scan.
    public func decodePayload(_ encoded: String) throws -> ConfigTransferPayload {
        guard let data = Data(base64Encoded: encoded) else {
            throw ConfigTransferError.invalidFormat
        }
        
        let deobfuscated = deobfuscate(data: data)
        return try decoder.decode(ConfigTransferPayload.self, from: deobfuscated)
    }
    
    /// Validates that a payload is recent (within 10 minutes) to prevent replay.
    public func validatePayloadFreshness(_ payload: ConfigTransferPayload, maxAge: TimeInterval = 600) -> Bool {
        abs(payload.timestamp.timeIntervalSinceNow) < maxAge
    }
    
    // MARK: - Simple Obfuscation
    // Note: This is NOT secure encryption. For sensitive data transfer,
    // implement proper AES encryption with a user-provided PIN.
    
    private let obfuscationKey: [UInt8] = [0x53, 0x70, 0x65, 0x61, 0x6B, 0x21] // "Speak!"
    
    private func obfuscate(data: Data) -> Data {
        var result = Data(count: data.count)
        for (index, byte) in data.enumerated() {
            result[index] = byte ^ obfuscationKey[index % obfuscationKey.count]
        }
        return result
    }
    
    private func deobfuscate(data: Data) -> Data {
        // XOR is its own inverse
        obfuscate(data: data)
    }
}

public enum ConfigTransferError: LocalizedError {
    case invalidFormat
    case payloadExpired
    case decodingFailed
    
    public var errorDescription: String? {
        switch self {
        case .invalidFormat:
            return "Invalid QR code format. Please scan a valid Speak configuration code."
        case .payloadExpired:
            return "This configuration code has expired. Please generate a new one."
        case .decodingFailed:
            return "Failed to decode configuration. The code may be corrupted."
        }
    }
}

// MARK: - Sync Status

/// Represents the current sync status across platforms.
public struct SyncStatus {
    public let iCloudKeychainAvailable: Bool
    public let iCloudKVStoreAvailable: Bool
    public let lastSyncDate: Date?
    public let pendingChanges: Bool
    
    public init(
        iCloudKeychainAvailable: Bool = false,
        iCloudKVStoreAvailable: Bool = false,
        lastSyncDate: Date? = nil,
        pendingChanges: Bool = false
    ) {
        self.iCloudKeychainAvailable = iCloudKeychainAvailable
        self.iCloudKVStoreAvailable = iCloudKVStoreAvailable
        self.lastSyncDate = lastSyncDate
        self.pendingChanges = pendingChanges
    }
    
    /// Checks current sync availability
    public static func current() -> SyncStatus {
        let sync = SettingsSync.shared
        
        return SyncStatus(
            iCloudKeychainAvailable: sync.isAvailable,
            iCloudKVStoreAvailable: sync.isAvailable,
            lastSyncDate: sync.lastSyncDate,
            pendingChanges: false
        )
    }
}
