#if os(iOS)
import Foundation
import SpeakCore

@MainActor
// swiftlint:disable:next type_name
public final class iOSSettingsSyncAdapter: SettingsTransportDelegate {
    public static let shared = iOSSettingsSyncAdapter()

    private let settings: AppSettings
    private let settingsSync: SettingsSync
    private let connection: MacConnection
    private var observers: [NSObjectProtocol] = []
    private var isApplyingRemoteRecords = false
    private var isStarted = false

    public convenience init() {
        self.init(settings: .shared, settingsSync: .shared, connection: .shared)
    }

    init(settings: AppSettings, settingsSync: SettingsSync, connection: MacConnection) {
        self.settings = settings
        self.settingsSync = settingsSync
        self.connection = connection
    }

    public func start() {
        guard !isStarted else { return }
        isStarted = true

        observers.append(NotificationCenter.default.addObserver(
            forName: SettingsSync.didChangeLocalRecordsNotification,
            object: settingsSync,
            queue: nil
        ) { [weak self] notification in
            Task { @MainActor in
                self?.handleLocalChange(notification)
            }
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: SettingsSync.didReceiveRemoteChangesNotification,
            object: settingsSync,
            queue: nil
        ) { [weak self] notification in
            Task { @MainActor in
                self?.handleRemoteChange(notification)
            }
        })

        settings.applySyncedSettings(records: settingsSync.recordsSnapshot())
        settings.publishCurrentSyncedSettings()
        connection.settingsTransportDelegate = self
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    public func settingsSnapshot(maxRecords: Int) -> [SyncedSettingRecord] {
        Array(settingsSync.recordsSnapshot().prefix(maxRecords))
    }

    public func applySettingsBatch(records: [SyncedSettingRecord]) async -> [SettingsSync.SyncKey] {
        isApplyingRemoteRecords = true
        defer { isApplyingRemoteRecords = false }
        let changed = settingsSync.mergeIncomingRecords(records, notifyObservers: false)
        let changedRecords = changed.compactMap { settingsSync.record(forKey: $0) }
        settings.applySyncedSettings(records: changedRecords)
        return changed
    }

    private func handleLocalChange(_ notification: Notification) {
        guard !isApplyingRemoteRecords else { return }
        let records = changedRecords(from: notification)
        guard !records.isEmpty else { return }
        let connection = connection
        Task { @MainActor [weak connection] in
            await connection?.broadcastSettingsDelta(records: records)
        }
    }

    private func handleRemoteChange(_ notification: Notification) {
        let records = changedRecords(from: notification)
        guard !records.isEmpty else { return }
        settings.applySyncedSettings(records: records)
        let connection = connection
        Task { @MainActor [weak connection] in
            await connection?.broadcastSettingsDelta(records: records)
        }
    }

    private func changedRecords(from notification: Notification) -> [SyncedSettingRecord] {
        let keys = notification.userInfo?[SettingsSync.changedKeysUserInfoKey] as? [SettingsSync.SyncKey]
        return (keys ?? SettingsSync.SyncKey.allCases).compactMap { settingsSync.record(forKey: $0) }
    }
}
#endif
