import CloudKit
import Foundation

/// Recognises the CloudKit push that announces a history change (issue #1007).
///
/// The database subscription was already being created on both platforms, but
/// neither `didReceiveRemoteNotification` looked at it: iOS sent every push to
/// the API-key sync and the Mac did the same, so a transcript captured on the
/// phone reached a running Mac only at its next launch.
///
/// The check is deliberately narrow — a push is only a history push when
/// CloudKit itself says the subscription id matches — so an API-key push, a
/// silent wake, or any future subscription is left to its own handler.
public enum HistorySyncPushRouting {
    public static func isHistoryChange(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) else {
            return false
        }
        return notification.subscriptionID == SyncConfiguration.historySubscriptionID
    }
}
