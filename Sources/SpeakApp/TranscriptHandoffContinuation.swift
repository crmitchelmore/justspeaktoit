import AppKit
import Foundation
import SpeakCore

/// The Mac end of the "Continue on Mac" pointer (issue #1006).
///
/// The Handoff payload is a pointer, not a transfer: it names a History entry
/// and nothing else. So continuing resolves the entry from this Mac's own
/// synced History and pastes it. When the entry has not arrived yet — Handoff
/// is advertised over the local link and can easily beat a CloudKit round trip
/// — the user is told exactly that instead of being shown a silent no-op or,
/// worse, a claim that something was pasted (issues #945, #952).
@MainActor
enum TranscriptHandoffContinuation {
    enum Result: Equatable {
        case notAPointer
        case pasted
        case pasteFailed(String)
        case notSyncedYet
    }

    /// - Parameters:
    ///   - lookup: resolves the pointer's entry to its text, or `nil` when this
    ///     Mac has not synced it.
    ///   - paste: the Mac's existing text-insertion path.
    @discardableResult
    static func handle(
        userInfo: [AnyHashable: Any]?,
        lookup: (UUID) -> String?,
        paste: (String) -> TextOutputResult,
        presentUnresolved: (String) -> Void
    ) -> Result {
        guard let pointer = TranscriptHandoffActivity.pointer(from: userInfo) else {
            return .notAPointer
        }
        guard let text = lookup(pointer.entryID), !text.isEmpty else {
            presentUnresolved(TranscriptHandoffActivity.unresolvedMessage)
            return .notSyncedYet
        }
        let result = paste(text)
        if let error = result.error {
            return .pasteFailed(error.localizedDescription)
        }
        return result.method == .none ? .pasteFailed("The transcript was not inserted.") : .pasted
    }

    static func presentUnresolvedAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Not on this Mac yet"
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.runModal()
    }
}

@MainActor
extension AppDelegate {
    /// The "Continue on Mac" Handoff pointer from an iPhone or Apple Watch
    /// capture (issue #1006). The payload names a History entry; the text comes
    /// from this Mac's own synced History.
    func application(
        _ application: NSApplication,
        continue userActivity: NSUserActivity,
        restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void
    ) -> Bool {
        guard userActivity.activityType == TranscriptHandoffActivity.activityType,
              let environment
        else {
            return false
        }
        let settings = environment.settings
        let permissions = environment.permissions
        let result = TranscriptHandoffContinuation.handle(
            userInfo: userActivity.userInfo,
            lookup: { id in
                guard let item = environment.history.item(id: id) else { return nil }
                return item.postProcessedTranscription ?? item.rawTranscription
            },
            paste: { text in
                SmartTextOutput(permissionsManager: permissions, appSettings: settings)
                    .output(text: text, target: nil)
            },
            presentUnresolved: TranscriptHandoffContinuation.presentUnresolvedAlert
        )
        return result != .notAPointer
    }
}
