import Foundation
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost
import SpeakDesktopSync
import SpeakSync
import SpeakLinuxPlatform
import CLinuxSupport

/// iCloud sync for the window: the shared flow (`DesktopHostCloudSync`) with
/// the iCloud sync group, URLSession, OpenSSL, the Secret Service keyring and
/// the POSIX loopback listener.
typealias LinuxCloudSync = DesktopHostCloudSync<LinuxHostPlatform>

extension DesktopHostCloudSync where Platform == LinuxHostPlatform {
    /// Creates sync for a real (not smoke-test) window before it opens. It
    /// reads nothing from the keyring or iCloud until `start`.
    static func configure(_ holder: LinuxEventContext) {
        guard !holder.smokeTest else { return }
        let controller = holder.controller
        do {
            // Sync state sits beside History, private to this user.
            try LinuxFiles.preparePrivateDirectory(
                LinuxCloudSync.stateURL(in: controller.directory).deletingLastPathComponent()
            )
            holder.cloudSync = try LinuxCloudSync(
                controller: controller,
                resolution: DesktopCloudSyncConfiguration.resolve(
                    buildToken: CloudKitWebBuildConfiguration.apiToken,
                    buildEnvironment: CloudKitWebBuildConfiguration.environment,
                    processEnvironment: ProcessInfo.processInfo.environment
                ),
                transport: LinuxCloudKitTransport(),
                vault: LinuxCredentialVault(),
                cryptography: LinuxEnvelopeCryptography(),
                native: DesktopHostCloudSyncNative(
                    originPlatform: DesktopHistorySyncProjection.linuxOriginPlatform,
                    settingsLocation: "under iCloud sync",
                    present: { status in LinuxCloudSync.present(status) },
                    listen: { port in try LinuxLoopbackListener(port: port) },
                    openSignInPage: { page in try LinuxSignInPage.open(page) }
                )
            )
        } catch {
            present(unavailable: "iCloud sync could not start: \(error.localizedDescription)")
        }
    }

    /// Starts sync once the controller has shown the saved History, so a
    /// synced change cannot land before that and be replaced by it.
    static func start(_ holder: LinuxEventContext, after ready: Task<Void, Never>) {
        guard let sync = holder.cloudSync else { return }
        let controller = holder.controller
        Task {
            await ready.value
            await sync.start(controller: controller)
        }
    }

    /// Once the window has closed: nothing new starts and nothing more
    /// reaches it, then the cancelled work gets the shutdown grace to end.
    static func shutDown(_ holder: LinuxEventContext) async {
        guard let sync = holder.cloudSync else { return }
        await sync.drain(sync.stop())
    }

    /// Hands the iCloud sync group its state; the shared flow calls this only
    /// while sync runs.
    private static func present(_ status: DesktopCloudSyncStatus) {
        status.summary.withCString { text in
            var view = JSTICloudSyncView(
                status: text,
                available: status.unavailableReason == nil ? 1 : 0,
                signed_in: status.isSignedIn ? 1 : 0,
                history_enabled: status.historyEnabled ? 1 : 0,
                key_import_enabled: status.apiKeyImportEnabled ? 1 : 0
            )
            _ = jsti_window_set_cloud_sync(&view)
        }
    }

    private static func present(unavailable reason: String) {
        reason.withCString { text in
            var view = JSTICloudSyncView(
                status: text, available: 0, signed_in: 0, history_enabled: 0, key_import_enabled: 0
            )
            _ = jsti_window_set_cloud_sync(&view)
        }
    }
}

/// The iCloud sync group's events, on the GTK thread. Returns false for others.
func linuxCloudSyncEvent(_ event: Int, value: String, slot: Int, holder: LinuxEventContext) -> Bool {
    let action: LinuxCloudSync.Action
    switch event {
    case Int(JSTI_EVENT_CLOUD_SYNC_APPLY):
        action = .apply(history: slot & 1 != 0, keys: slot & 2 != 0, passphrase: value)
    case Int(JSTI_EVENT_CLOUD_SYNC_SIGN_IN): action = .signIn
    case Int(JSTI_EVENT_CLOUD_SYNC_SIGN_OUT): action = .signOut
    case Int(JSTI_EVENT_CLOUD_SYNC_NOW): action = .syncNow
    default: return false
    }
    holder.cloudSync?.handle(action)
    return true
}
