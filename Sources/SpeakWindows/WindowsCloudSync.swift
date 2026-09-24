import Foundation
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost
import SpeakDesktopSync
import SpeakSync
import SpeakWindowsPlatform
import CWindowsSupport

/// Hooks the controller calls into iCloud sync once it is configured.
typealias WindowsCloudSyncHooks = DesktopHostSyncHooks

/// iCloud sync for the window: the shared flow (`DesktopHostCloudSync`) with
/// the Settings dialog, WinHTTP, CNG, Credential Manager and the Winsock
/// loopback listener.
typealias WindowsCloudSync = DesktopHostCloudSync<WindowsHostPlatform>

/// Windows Credential Manager as the sync credential vault: the rotating web
/// auth token, the API-key sync key and imported provider keys.
struct WindowsCredentialVault: DesktopCredentialVault {
    func readCredential(_ name: String) throws -> String? {
        let value = try WindowsNative.apiKey(name: name)
        return value.isEmpty ? nil : value
    }

    func writeCredential(_ value: String, name: String) throws {
        try WindowsNative.saveAPIKey(value, name: name)
    }

    func deleteCredential(_ name: String) throws {
        try WindowsNative.saveAPIKey("", name: name)
    }
}

extension WindowsLoopbackListener: DesktopLoopbackListener {
    public func nextRequest(within timeout: Duration) async throws -> Connection? {
        do {
            return try await accept(timeout: timeout)
        } catch Failure.timedOut {
            return nil
        }
    }
}

extension WindowsLoopbackListener.Connection: DesktopLoopbackRequest {}

/// The window's event context as a sendable value, for the dialog callback.
private struct WindowsSyncContext: @unchecked Sendable {
    let pointer: UnsafeMutableRawPointer
}

extension DesktopHostCloudSync where Platform == WindowsHostPlatform {
    /// Creates sync for a running (not smoke-test) window and shows the dialog's state.
    static func configure(_ holder: WindowsEventContext) async {
        guard !holder.smokeTest else { return }
        let context = WindowsSyncContext(pointer: Unmanaged.passUnretained(holder).toOpaque())
        do {
            let sync = try WindowsCloudSync(
                controller: holder.controller,
                resolution: DesktopCloudSyncConfiguration.resolve(
                    buildToken: CloudKitWebBuildConfiguration.apiToken,
                    buildEnvironment: CloudKitWebBuildConfiguration.environment,
                    processEnvironment: ProcessInfo.processInfo.environment
                ),
                transport: WinHTTPCloudKitTransport(),
                vault: WindowsCredentialVault(),
                cryptography: WindowsEnvelopeCryptography(),
                native: DesktopHostCloudSyncNative(
                    originPlatform: DesktopHistorySyncProjection.originPlatform,
                    settingsLocation: "in Settings, iCloud sync",
                    present: { status in WindowsCloudSync.present(status, context: context) },
                    listen: { port in try WindowsLoopbackListener(port: port) },
                    openSignInPage: { page in
                        try page.absoluteString.withCString { url in
                            try WindowsNative.checked { jsti_shell_open_sign_in_page(url, $0, $1) }
                        }
                    }
                )
            )
            holder.cloudSync = sync
            await sync.start(controller: holder.controller)
        } catch {
            WindowsNative.update("iCloud sync could not start: \(error.localizedDescription)")
        }
    }

    /// Stops sync before the window's context can be released: nothing new
    /// starts and nothing more reaches the window, then the dialog is
    /// detached and the cancelled work gets the shutdown grace to end.
    static func shutDown(_ holder: WindowsEventContext) async {
        let sync = holder.cloudSync
        let running = sync?.stop() ?? []
        jsti_window_clear_cloud_sync()
        await sync?.drain(running)
    }

    /// Hands the dialog its state; the shared flow calls this only while sync
    /// runs, so the dialog cannot be given this window's context again after
    /// shutdown detached it.
    private static func present(_ status: DesktopCloudSyncStatus, context: WindowsSyncContext) {
        status.summary.withCString { text in
            var view = JSTICloudSyncView(
                status: text,
                available: status.unavailableReason == nil ? 1 : 0,
                signed_in: status.isSignedIn ? 1 : 0,
                history_enabled: status.historyEnabled ? 1 : 0,
                key_import_enabled: status.apiKeyImportEnabled ? 1 : 0
            )
            _ = jsti_window_set_cloud_sync(&view, cloudSyncEvent, context.pointer)
        }
    }
}

/// The iCloud sync dialog's single action, on the UI thread: 1 apply choices,
/// 2 sign in, 3 sign out, 4 sync now. The passphrase is copied before the
/// native buffer is wiped.
func cloudSyncEvent(
    _ action: Int32, _ history: Int32, _ keys: Int32, _ passphrase: UnsafePointer<CChar>?,
    _ context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    let holder = Unmanaged<WindowsEventContext>.fromOpaque(context).takeUnretainedValue()
    let typed = passphrase.map(String.init(cString:)) ?? ""
    switch action {
    case 1: holder.cloudSync?.handle(.apply(history: history == 1, keys: keys == 1, passphrase: typed))
    case 2: holder.cloudSync?.handle(.signIn)
    case 3: holder.cloudSync?.handle(.signOut)
    case 4: holder.cloudSync?.handle(.syncNow)
    default: break
    }
}

/// Saving a key by hand keeps it from being removed by a later remote deletion;
/// with sync configured the controller saves and marks it in one step.
func saveKeyEvent(_ value: String, index: Int, holder: WindowsEventContext) {
    let controller = holder.controller
    holder.enqueueSettings { await controller.saveKey(value, modelIndex: index) }
}

extension SpeakWindowsMain {
    /// Saved automation and iCloud sync, once the window's dialogs are configured.
    static func restoreServices(_ holder: WindowsEventContext) async {
        if !holder.smokeTest { await WindowsAutomationSwitch.restore(holder) }
        await WindowsCloudSync.configure(holder)
    }

    /// Detaches dialogs that hold the event context before it can be released.
    static func releaseServices(_ holder: WindowsEventContext) async {
        jsti_window_clear_voice_output()
        jsti_window_clear_local_models()
        await WindowsCloudSync.shutDown(holder)
    }
}
