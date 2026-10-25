#if os(iOS)
import Foundation
import UserNotifications

/// Cross-module notification adapter used by the existing application delegate.
public enum TranscriptReadyNotificationRoute {
    public static let categoryIdentifier = "transcript-ready"
    public static let openHistoryAction = "transcript-ready.open-history"
    static let requestPrefix = "transcript-ready."

    static func requestIdentifier(for identifier: UUID) -> String {
        self.requestPrefix + identifier.uuidString
    }

    static func content(for identifier: UUID) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Transcript ready"
        content.body = "Open History to view your saved transcription"
        content.categoryIdentifier = self.categoryIdentifier
        content.threadIdentifier = self.categoryIdentifier
        content.userInfo = ["schema": 1, "historyID": identifier.uuidString]
        return content
    }

    public static func historyID(from userInfo: [AnyHashable: Any]) -> UUID? {
        guard Set(userInfo.keys) == Set([AnyHashable("schema"), AnyHashable("historyID")]),
              let schema = userInfo["schema"] as? Int, schema == 1,
              let value = userInfo["historyID"] as? String else { return nil }
        return UUID(uuidString: value)
    }

    static func savedItem(identifier: UUID, items: [iOSHistoryItem]) -> iOSHistoryItem? {
        items.first { $0.id == identifier }
    }

    @MainActor
    @discardableResult
    public static func openHistory(category: String, action: String, userInfo: [AnyHashable: Any]) -> Bool {
        guard category == self.categoryIdentifier,
              action == UNNotificationDefaultActionIdentifier || action == self.openHistoryAction,
              let identifier = self.historyID(from: userInfo) else { return false }
        DeepLinkRouter.shared.openHistory(identifier: identifier)
        return true
    }

    /// Complete the system callback promptly; only navigation waits for MainActor.
    public static func receive(
        category: String, action: String, userInfo: [AnyHashable: Any], completion: () -> Void
    ) {
        self.dispatchResponse(route: {
            _ = self.openHistory(category: category, action: action, userInfo: userInfo)
        }, completion: completion)
    }

    static func dispatchResponse(route: @escaping @MainActor () -> Void, completion: () -> Void) {
        Task { @MainActor in route() }
        completion()
    }

    @MainActor
    public static func reconcileDisabledPreference() {
        TranscriptReadyNotificationCoordinator.shared.reconcilePersistedPreference()
    }

    /// Merge with existing categories rather than claiming unrelated notifications.
    public static func registerCategory(in center: UNUserNotificationCenter = .current()) async {
        var categories = await center.notificationCategories()
        categories = categories.filter { $0.identifier != self.categoryIdentifier }
        let action = UNNotificationAction(
            identifier: self.openHistoryAction, title: "Open History", options: [.foreground, .authenticationRequired]
        )
        categories.insert(UNNotificationCategory(
            identifier: self.categoryIdentifier, actions: [action], intentIdentifiers: [], options: []
        ))
        center.setNotificationCategories(categories)
    }
}

extension TranscriptReadyNotificationCoordinator {
    static func live() -> TranscriptReadyNotificationCoordinator {
        let settings = AppSettings.shared
        let center = UNUserNotificationCenter.current()
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let ledger = TranscriptReadyNotificationLedger(
            url: directory.appendingPathComponent("TranscriptReady/claims.json")
        )
        let coordinator = TranscriptReadyNotificationCoordinator(
            center: TranscriptReadyNotificationCenter(
                authorized: {
                    let settings = await center.notificationSettings()
                    return settings.authorizationStatus == .authorized && settings.alertSetting == .enabled
                },
                requestAlertPermission: {
                    (try? await center.requestAuthorization(options: [.alert])) == true
                },
                enqueue: { identifier in
                    try await center.add(UNNotificationRequest(
                        identifier: TranscriptReadyNotificationRoute.requestIdentifier(for: identifier),
                        content: TranscriptReadyNotificationRoute.content(for: identifier), trigger: nil
                    ))
                },
                pendingIdentifiers: { await center.pendingNotificationRequests().map(\.identifier) },
                removePending: { center.removePendingNotificationRequests(withIdentifiers: $0) },
                removeDelivered: { center.removeDeliveredNotifications(withIdentifiers: $0) }
            ),
            isEnabled: { settings.transcriptReadyNotificationsEnabled },
            writeEnabled: { settings.transcriptReadyNotificationsEnabled = $0 },
            claim: { try ledger.claim($0, at: $1) },
            forget: { try ledger.forget($0) },
            historyExists: { identifier in
                let history = iOSHistoryManager.shared
                return history.isStorageReady && history.items.contains { $0.id == identifier }
            }
        )
        settings.transcriptReadyNotificationsDidDisable = { [weak coordinator] in coordinator?.disable() }
        return coordinator
    }
}
#endif
