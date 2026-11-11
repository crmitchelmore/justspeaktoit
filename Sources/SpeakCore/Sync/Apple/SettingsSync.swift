import Foundation
import os.log

// MARK: - Settings Sync using iCloud Key-Value Store

// The QR configuration transfer lives beside this file: its wire types in
// ConfigTransferModels, the manager in ConfigTransferManager (+Envelope for the
// AES-GCM/zlib codec, +Import for the transactional import). Its bounded
// secret-identifier policy stays at the end of this file.

/// Syncs non-secret preferences across devices using iCloud Key-Value Store.
/// For secrets/API keys, use SecureStorage with synchronizable=true.
/// 
/// NOTE: iCloud sync requires an Apple Developer subscription with iCloud entitlement.
/// Without it, this class fails gracefully - all operations become no-ops and
/// availability checks return false. Local settings still work via UserDefaults fallback.
///
/// `@unchecked Sendable` rests on these assumptions, not on a lock:
/// - `store` and `isAvailable` are assigned only in `init` and never mutated
///   afterwards, so concurrent reads see one immutable value;
/// - `NSUbiquitousKeyValueStore`, `UserDefaults` and `NotificationCenter` are
///   documented thread-safe, so every read and write delegates to them;
/// - the only callback is `storeDidChange(_:)`, which reads its notification
///   and posts; it touches no instance state.
/// Adding mutable state after `init` requires real isolation first.
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
            SpeakLogger.sync.info("iCloud not available - using local storage only")
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
            SpeakLogger.sync.error("iCloud KV store quota exceeded")
        case NSUbiquitousKeyValueStoreAccountChange:
            SpeakLogger.sync.notice("iCloud account changed")
        default:
            break
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

    /// Checks the build/runtime support for the Bonjour transport fallback.
    public static var currentTransportAvailable: Bool {
        DistributionChannel.current.supportsLocalNetworkTransport
            && !SpeakTransportServiceType.isEmpty
            && SpeakTransportProtocolVersion > 0
    }

    /// Checks current sync availability. CloudKit account availability is owned
    /// by SpeakSync, so callers pass the latest `HistorySyncEngine` state.
    public static func current(iCloudCloudKitAvailable: Bool = false) -> SyncAvailability {
        let sync = SettingsSync.shared

        return SyncAvailability(
            iCloudKVStoreAvailable: sync.isAvailable,
            iCloudCloudKitAvailable: iCloudCloudKitAvailable,
            transportAvailable: currentTransportAvailable,
            distributionChannel: .current
        )
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
        transportAvailable: Bool = SyncAvailability.currentTransportAvailable,
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
    public static func current(iCloudCloudKitAvailable: Bool = false) -> SyncStatus {
        let sync = SettingsSync.shared
        let availability = SyncAvailability.current(iCloudCloudKitAvailable: iCloudCloudKitAvailable)
        
        return SyncStatus(
            iCloudKeychainAvailable: KeychainSyncAvailability.isAvailable(),
            iCloudKVStoreAvailable: availability.iCloudKVStoreAvailable,
            iCloudCloudKitAvailable: availability.iCloudCloudKitAvailable,
            transportAvailable: availability.transportAvailable,
            lastSyncDate: sync.lastSyncDate,
            pendingChanges: false
        )
    }
}

// The bounded transfer policy lives in an extension so the manager's type body
// stays under the lint limit as providers are added.
extension ConfigTransferManager {
    /// This list is deliberately explicit rather than derived: it is the
    /// bounded transfer policy (issue #699). A parity test asserts it equals
    /// `ModelCredentialResolver.allKnownAPIKeyIdentifiers`, so adding a
    /// provider to any catalogue fails the test until its transfer capability
    /// is defined here. Dynamically registered identifiers are never exported.
    public static let transferableSecretIdentifiers: [String] = [
        "alibaba.apiKey",
        "anthropic.apiKey",
        "assemblyai.apiKey",
        "azure.speech.apiKey",
        "cartesia.apiKey",
        "deepgram.apiKey",
        "elevenlabs.apiKey",
        "gladia.apiKey",
        "google.apiKey",
        "groq.apiKey",
        "meta.apiKey",
        "mistral.apiKey",
        "modulate.apiKey",
        "openai.apiKey",
        "openai.tts.apiKey",
        "openrouter.apiKey",
        "reson8.apiKey",
        "revai.apiKey",
        "smallest.apiKey",
        "soniox.apiKey",
        "speechmatics.apiKey",
        "stepfun.apiKey",
        "xai.apiKey"
    ]
}
