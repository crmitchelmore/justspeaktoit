import AppKit
import Foundation
import SpeakCore
import SpeakSync
import UserNotifications

/// The Mac end of the CloudKit history lane (issue #1007).
///
/// iOS already uploaded every transcript to the shared zone within seconds of
/// the capture. What was missing was a Mac that noticed: the push was never
/// routed and the app only synced at launch, so a phone or watch capture sat
/// in iCloud until the next relaunch. This adds the three triggers that make
/// the lane work — the push, waking, and activation — and turns a fresh arrival
/// into something the user can act on in one click.
///
/// The Paste action, not an automatic paste, is the default. Auto-paste is
/// behind `AppSettings.pasteRemoteTranscriptsAtCursor` and reports what the
/// paste actually did (issues #945, #952).
@MainActor
final class RemoteTranscriptDelivery: NSObject {
    static let categoryIdentifier = "com.justspeaktoit.remote-transcript"
    static let pasteActionIdentifier = "paste"
    static let copyActionIdentifier = "copy"

    private let settings: AppSettings
    /// Injected so the delivery path is exercised without AppKit in tests and
    /// so this type never reaches into the accessibility stack itself.
    private let paste: (String) -> TextOutputResult
    private let notificationCenter: UNUserNotificationCenter?
    /// Resolves a transcript from durable local history by entry id, for
    /// notifications that outlive this process. Injected so the delivery path
    /// stays testable and this type never reaches into the history store.
    private let transcriptForEntry: (UUID) -> String?
    private var syncObservers: [NSObjectProtocol] = []
    /// The transcript each posted notification carries, as a fast path for the
    /// common case where the action is pressed while this process is still
    /// running. It is a cache, not the source of truth — see `transcript(for:)`.
    private var pendingTranscripts: [String: String] = [:]
    /// Insertion order for `pendingTranscripts`, oldest first.
    private var pendingOrder: [String] = []
    /// Cap on retained transcript text. Notifications that are dismissed,
    /// expire, or are never acted on would otherwise hold their full text for
    /// the life of the process, so sustained normal arrivals grow without
    /// bound. Evicted entries still resolve through local history.
    static let pendingTranscriptLimit = 20

    init(
        settings: AppSettings,
        paste: @escaping (String) -> TextOutputResult,
        notificationCenter: UNUserNotificationCenter? = RemoteTranscriptDelivery.systemNotificationCenter(),
        transcriptForEntry: @escaping (UUID) -> String? = { _ in nil }
    ) {
        self.settings = settings
        self.paste = paste
        self.notificationCenter = notificationCenter
        self.transcriptForEntry = transcriptForEntry
        super.init()
    }

    /// `UNUserNotificationCenter.current()` raises
    /// `bundleProxyForCurrentProcess is nil` in any process that is not an
    /// installed `.app` — the SwiftPM test runner and the CLI both are not — so
    /// the bundle shape, not just a bundle identifier, is what gates it.
    nonisolated static func systemNotificationCenter() -> UNUserNotificationCenter? {
        guard Bundle.main.bundleIdentifier != nil,
              Bundle.main.bundleURL.pathExtension == "app"
        else {
            return nil
        }
        return UNUserNotificationCenter.current()
    }

    // MARK: - Wiring

    func start() {
        registerCategory()
        observeSyncTriggers()
    }

    private func registerCategory() {
        guard let notificationCenter else { return }
        notificationCenter.delegate = self
        let paste = UNNotificationAction(
            identifier: Self.pasteActionIdentifier,
            title: "Paste",
            options: [.foreground]
        )
        let copy = UNNotificationAction(identifier: Self.copyActionIdentifier, title: "Copy", options: [])
        notificationCenter.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.categoryIdentifier,
                actions: [paste, copy],
                intentIdentifiers: [],
                options: []
            )
        ])
        notificationCenter.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// A push is best-effort — it needs the `aps-environment` entitlement and a
    /// device APNs can reach — so waking and activating sync as well. Together
    /// they are what makes the lane "always works" rather than "usually".
    private func observeSyncTriggers() {
        let workspace = NSWorkspace.shared.notificationCenter
        syncObservers.append(
            workspace.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in await HistorySyncEngine.shared.sync() }
            }
        )
        syncObservers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in await HistorySyncEngine.shared.sync() }
            }
        )
    }

    deinit {
        let observers = syncObservers
        MainActor.assumeIsolated {
            observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }

    // MARK: - Arrivals

    /// Called for every entry the history sync brings down.
    func handle(entry: SyncableHistoryEntry, isNewToThisMac: Bool, now: Date = Date()) {
        let text = entry.postProcessedText ?? entry.rawTranscription ?? ""
        let decision = RemoteTranscriptArrival.decide(
            RemoteTranscriptArrival.Input(
                originPlatform: entry.originPlatform,
                createdAt: entry.createdAt,
                text: text,
                isNewToThisMac: isNewToThisMac,
                autoPasteEnabled: settings.pasteRemoteTranscriptsAtCursor
            ),
            now: now
        )

        switch decision {
        case .ignore:
            return
        case .notify(let alert):
            post(alert, id: entry.id)
        case .pasteAtCursor(let alert):
            let result = paste(alert.transcript)
            let pasted = result.error == nil && result.method != .none
            post(
                RemoteTranscriptArrival.outcomeAlert(
                    for: alert,
                    pasted: pasted,
                    failureReason: result.error?.localizedDescription
                ),
                id: entry.id
            )
        }
    }

    private func post(_ alert: RemoteTranscriptArrival.Alert, id: UUID) {
        guard let notificationCenter else { return }
        remember(alert.transcript, for: id.uuidString)
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.categoryIdentifier = Self.categoryIdentifier
        notificationCenter.add(
            UNNotificationRequest(identifier: id.uuidString, content: content, trigger: nil)
        )
    }

    private func remember(_ transcript: String, for identifier: String) {
        if pendingTranscripts[identifier] == nil {
            pendingOrder.append(identifier)
        }
        pendingTranscripts[identifier] = transcript
        while pendingOrder.count > Self.pendingTranscriptLimit {
            pendingTranscripts.removeValue(forKey: pendingOrder.removeFirst())
        }
    }

    private func forget(_ identifier: String) {
        pendingTranscripts.removeValue(forKey: identifier)
        pendingOrder.removeAll { $0 == identifier }
    }

    /// The transcript a notification's action should act on.
    ///
    /// The in-memory cache is only a fast path. A notification stays actionable
    /// across a quit, a crash or a relaunch, and its identifier is the History
    /// entry id — which the entry that produced the notification also has, in
    /// durable local history. Falling back to that is what stops a Paste or
    /// Copy chosen after an ordinary process lifecycle event from silently
    /// doing nothing.
    func transcript(for identifier: String) -> String? {
        if let cached = pendingTranscripts[identifier] { return cached }
        guard let entryID = UUID(uuidString: identifier) else { return nil }
        return transcriptForEntry(entryID)
    }
}

// MARK: - Notification actions

extension RemoteTranscriptDelivery: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let identifier = response.notification.request.identifier
        let action = response.actionIdentifier
        Task { @MainActor in
            self.perform(action: action, forNotification: identifier)
            completionHandler()
        }
    }

    @discardableResult
    func perform(action: String, forNotification identifier: String) -> Bool {
        guard action == Self.pasteActionIdentifier || action == Self.copyActionIdentifier else {
            return false
        }
        guard let transcript = transcript(for: identifier) else {
            // The transcript is genuinely unrecoverable (the entry was deleted,
            // or history is unavailable). Say so rather than discarding a
            // deliberate user action in silence.
            reportUnresolvableAction(for: identifier)
            return false
        }
        forget(identifier)
        switch action {
        case Self.pasteActionIdentifier:
            _ = paste(transcript)
        case Self.copyActionIdentifier:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(transcript, forType: .string)
        default:
            break
        }
        return true
    }

    private func reportUnresolvableAction(for identifier: String) {
        guard let notificationCenter else { return }
        let content = UNMutableNotificationContent()
        content.title = "Transcript unavailable"
        content.body = "That transcript is no longer on this Mac, so it could not be pasted or copied."
        notificationCenter.add(
            UNNotificationRequest(
                identifier: "\(identifier).unresolved",
                content: content,
                trigger: nil
            )
        )
    }
}
