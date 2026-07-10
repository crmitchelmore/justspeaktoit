#if os(macOS)
import Foundation
import SpeakCore

@MainActor
final class MacSettingsSyncAdapter: SettingsTransportDelegate {
  private let settings: AppSettings
  private let settingsSync: SettingsSync
  private weak var transportServer: TransportServer?
  private var observers: [NSObjectProtocol] = []
  private var isApplyingRemoteRecords = false
  private var isStarted = false

  init(settings: AppSettings, settingsSync: SettingsSync = .shared, transportServer: TransportServer) {
    self.settings = settings
    self.settingsSync = settingsSync
    self.transportServer = transportServer
  }

  func start() {
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
    transportServer?.settingsTransportDelegate = self
  }

  deinit {
    for observer in observers {
      NotificationCenter.default.removeObserver(observer)
    }
  }

  func settingsSnapshot(maxRecords: Int) -> [SyncedSettingRecord] {
    Array(settingsSync.recordsSnapshot().prefix(maxRecords))
  }

  func applySettingsBatch(records: [SyncedSettingRecord]) async -> [SettingsSync.SyncKey] {
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
    let transportServer = transportServer
    Task { @MainActor [weak transportServer] in
      await transportServer?.broadcastSettingsDelta(records: records)
    }
  }

  private func handleRemoteChange(_ notification: Notification) {
    let records = changedRecords(from: notification)
    guard !records.isEmpty else { return }
    settings.applySyncedSettings(records: records)
    let transportServer = transportServer
    Task { @MainActor [weak transportServer] in
      await transportServer?.broadcastSettingsDelta(records: records)
    }
  }

  private func changedRecords(from notification: Notification) -> [SyncedSettingRecord] {
    let keys = notification.userInfo?[SettingsSync.changedKeysUserInfoKey] as? [SettingsSync.SyncKey]
    return (keys ?? SettingsSync.SyncKey.allCases).compactMap { settingsSync.record(forKey: $0) }
  }
}
#endif
