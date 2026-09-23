import Foundation
import SpeakCore
import SpeakDesktop
import SpeakDesktopSync
import SpeakSync
import SpeakWindowsPlatform
import CWindowsSupport

/// Hooks the controller calls into iCloud sync once it is configured.
struct WindowsCloudSyncHooks: Sendable {
    var historyChanged: (@Sendable () -> Void)?
}

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

/// iCloud sync for the window: the Settings dialog, the loopback Apple ID
/// sign-in, and a periodic pass. Nothing syncs until the user signs in and
/// chooses History or key import in the dialog.
final class WindowsCloudSync: @unchecked Sendable {
    static let interval: Duration = .seconds(300)
    static let signInWindow: Duration = .seconds(600)

    let service: DesktopCloudSyncService
    private let lock = NSLock()
    private var context: UnsafeMutableRawPointer?
    private var loop: Task<Void, Never>?
    private var signIn: Task<Void, Never>?

    init(controller: WindowsAppController, directory: URL) throws {
        let resolution = DesktopCloudSyncConfiguration.resolve(
            buildToken: CloudKitWebBuildConfiguration.apiToken,
            buildEnvironment: CloudKitWebBuildConfiguration.environment,
            processEnvironment: ProcessInfo.processInfo.environment
        )
        let state = try DesktopCloudSyncStateStore(
            url: directory.appendingPathComponent("CloudSync").appendingPathComponent("state.json")
        )
        let history = DesktopHistorySyncStore(
            records: controller.store,
            state: state,
            onChanges: { changes in await controller.applySyncedHistory(changes) }
        )
        service = DesktopCloudSyncService(
            resolution: resolution,
            transport: WinHTTPCloudKitTransport(),
            vault: WindowsCredentialVault(),
            state: state,
            historyStore: history,
            cryptography: WindowsEnvelopeCryptography()
        )
    }

    /// Creates sync for a running (not smoke-test) window and shows the dialog's state.
    static func configure(_ holder: WindowsEventContext) async {
        guard !holder.smokeTest else { return }
        do {
            let sync = try WindowsCloudSync(controller: holder.controller, directory: holder.controller.directory)
            holder.cloudSync = sync
            await sync.start(context: Unmanaged.passUnretained(holder).toOpaque(), controller: holder.controller)
        } catch {
            WindowsNative.update("iCloud sync could not start: \(error.localizedDescription)")
        }
    }

    static func shutDown(_ holder: WindowsEventContext) async {
        jsti_window_clear_cloud_sync()
        holder.cloudSync?.stop()
    }

    private func start(context: UnsafeMutableRawPointer, controller: WindowsAppController) async {
        lock.withLock { self.context = context }
        await service.prepare()
        await controller.installCloudSync(WindowsCloudSyncHooks { [weak self] in self?.requestSync() })
        await publish()
        let task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.runSync(announce: false)
                try? await Task.sleep(for: Self.interval)
            }
        }
        lock.withLock { loop = task }
    }

    private func stop() {
        let tasks = lock.withLock { () -> [Task<Void, Never>?] in
            context = nil
            return [loop, signIn]
        }
        tasks.forEach { $0?.cancel() }
    }

    /// A local History change: sync soon. The service serialises passes and a
    /// change during a pass runs one follow-up pass.
    func requestSync() {
        Task { [weak self] in await self?.runSync(announce: false) }
    }

    // MARK: - Dialog actions (from the UI thread)

    func handle(action: Int32, history: Bool, keys: Bool, passphrase: String) {
        switch action {
        case 1: Task { await self.apply(history: history, keys: keys, passphrase: passphrase) }
        case 2:
            let task = Task<Void, Never> { [weak self] in await self?.performSignIn() }
            let previous = lock.withLock { () -> Task<Void, Never>? in
                defer { signIn = task }
                return signIn
            }
            previous?.cancel()
        case 3: Task { await self.signOut() }
        case 4: Task { await self.runSync(announce: true) }
        default: break
        }
    }

    private func apply(history: Bool, keys: Bool, passphrase: String) async {
        do {
            try await service.setHistoryEnabled(history)
            let importing = await service.status().apiKeyImportEnabled
            if keys, !importing {
                guard !passphrase.isEmpty else {
                    WindowsNative.update("Enter the API-key sync passphrase from your Mac to import its keys.")
                    await publish()
                    return
                }
                let report = try await service.enableKeyImport(passphrase: passphrase)
                WindowsNative.update(Self.describe(imported: report.importedKeys))
            } else if !keys, importing {
                try await service.disableKeyImport()
            }
            await runSync(announce: !keys || importing)
        } catch {
            WindowsNative.update("iCloud sync: \(error.localizedDescription)")
            await publish()
        }
    }

    private func signOut() async {
        do {
            try await service.signOut()
            WindowsNative.update("Signed out of iCloud on this PC. History and saved keys stay on this PC.")
        } catch { WindowsNative.update("iCloud sign-out: \(error.localizedDescription)") }
        await publish()
    }

    private func runSync(announce: Bool) async {
        let report = await service.sync()
        if let error = report.error {
            if announce { WindowsNative.update("iCloud sync: \(error)") }
        } else if !report.importedKeys.isEmpty {
            WindowsNative.update(Self.describe(imported: report.importedKeys))
        } else if announce {
            WindowsNative.update(await service.status().summary)
        }
        await publish()
    }

    // MARK: - Sign-in

    /// Opens Apple's sign-in page and waits for its redirect to the loopback
    /// callback registered on the container's API token.
    private func performSignIn() async {
        do {
            guard let page = try await service.signInPage() else {
                WindowsNative.update("Already signed in to iCloud.")
                await runSync(announce: true)
                return
            }
            let listener = try WindowsLoopbackListener(port: DesktopCloudSyncSignIn.callbackPort)
            defer { listener.close() }
            try page.absoluteString.withCString { url in
                try WindowsNative.checked { jsti_shell_open_sign_in_page(url, $0, $1) }
            }
            WindowsNative.update("Finish signing in with your Apple ID in your browser.")
            let token = try await Self.awaitCallback(on: listener)
            try await service.completeSignIn(webAuthToken: token)
            WindowsNative.update("Signed in to iCloud. Choose what to sync in Settings, iCloud sync.")
            await runSync(announce: false)
        } catch is CancellationError {
            return
        } catch {
            WindowsNative.update("iCloud sign-in did not finish: \(error.localizedDescription)")
        }
        await publish()
    }

    private static func awaitCallback(on listener: WindowsLoopbackListener) async throws -> String {
        let deadline = ContinuousClock.now + signInWindow
        while true {
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero else { throw WindowsLoopbackListener.Failure.timedOut }
            let connection = try await listener.accept(timeout: remaining)
            if let target = connection.target,
               let token = DesktopCloudSyncSignIn.webAuthToken(fromRequestTarget: target) {
                connection.respond(callbackPage(
                    "Signed in", "You are signed in to iCloud. You can close this tab and return to Just Speak to It."
                ))
                return token
            }
            connection.respond(callbackPage("Not found", "This address only completes iCloud sign-in.", status: 404))
        }
    }

    private static func callbackPage(_ title: String, _ message: String, status: Int = 200) -> Data {
        let body = "<!doctype html><meta charset=\"utf-8\"><title>\(title)</title><p>\(message)</p>"
        let head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Not Found")\r\n"
            + "Content-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\n"
            + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
        return Data((head + body).utf8)
    }

    // MARK: - Dialog state

    private func publish() async {
        let status = await service.status()
        guard let context = lock.withLock({ self.context }) else { return }
        status.summary.withCString { text in
            var view = JSTICloudSyncView(
                status: text,
                available: status.unavailableReason == nil ? 1 : 0,
                signed_in: status.isSignedIn ? 1 : 0,
                history_enabled: status.historyEnabled ? 1 : 0,
                key_import_enabled: status.apiKeyImportEnabled ? 1 : 0
            )
            _ = jsti_window_set_cloud_sync(&view, cloudSyncEvent, context)
        }
    }

    static func describe(imported identifiers: [String]) -> String {
        guard !identifiers.isEmpty else { return "No new API keys to import from your Mac." }
        let providers = WindowsModels.all.compactMap { WindowsModels.provider(for: $0.id) }
        let names = identifiers.sorted().map { identifier in
            providers.first { $0.apiKeyIdentifier == identifier }?.displayName ?? identifier
        }
        return "Imported API keys from your Mac: \(names.joined(separator: ", "))."
    }
}

/// The iCloud sync dialog's single action, on the UI thread. The passphrase is
/// copied before the native buffer is wiped.
func cloudSyncEvent(
    _ action: Int32, _ history: Int32, _ keys: Int32, _ passphrase: UnsafePointer<CChar>?,
    _ context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    let holder = Unmanaged<WindowsEventContext>.fromOpaque(context).takeUnretainedValue()
    let typed = passphrase.map(String.init(cString:)) ?? ""
    holder.cloudSync?.handle(action: action, history: history == 1, keys: keys == 1, passphrase: typed)
}

/// Saving a key by hand keeps it from being removed by a later remote deletion.
func saveKeyEvent(_ value: String, index: Int, holder: WindowsEventContext) {
    let controller = holder.controller
    let sync = holder.cloudSync
    holder.enqueueSettings {
        await controller.saveKey(value, modelIndex: index)
        guard WindowsModels.all.indices.contains(index),
              let provider = WindowsModels.provider(for: WindowsModels.all[index].id) else { return }
        await sync?.service.noteManualKeySave(identifier: provider.apiKeyIdentifier)
    }
}

extension WindowsAppController {
    func installCloudSync(_ hooks: WindowsCloudSyncHooks) {
        cloudSync = hooks
    }

    /// Shows History changes that sync has already saved. Rows update at once;
    /// the displayed transcript is re-rendered only for the selected record and
    /// only while nothing else owns the transcript area. A removed selection is
    /// cleared, so no action can target a record that no longer exists.
    func applySyncedHistory(_ changes: [DesktopHistorySyncChange]) async {
        guard !closed else { return }
        var selectedChanged = false
        for change in changes {
            switch change {
            case .saved(let id):
                guard let record = await store.existingRecord(id: id) else { continue }
                indexHistory(record)
                selectedChanged = selectedChanged || id == selectedHistoryID
            case .removed(let id):
                history[id] = nil
                historySearchText[id] = nil
                if id == selectedHistoryID {
                    playback.stop()
                    stopReadAloud()
                    selectedHistoryID = nil
                    transcript = ""
                    transcriptVariant = .processed
                    WindowsNative.transcriptVariant(nil, for: nil, switchable: false)
                    update("The selected recording was deleted on another device.", transcript: "")
                }
            case .keptAfterRemoteDeletion:
                continue
            }
        }
        refreshHistory()
        if selectedChanged, canUseHistory, let id = selectedHistoryID, let record = history[id] {
            transcript = record.text(for: transcriptVariant) ?? ""
            WindowsNative.historyPresentation(record, variant: transcriptVariant, status: "Updated from iCloud.")
        }
    }

    /// A transcript synced from another device has no audio here.
    func refuseSyncedAudio(_ record: DesktopRecordingStore.Record) -> Bool {
        guard record.isSyncedCopy else { return false }
        update("This transcript was synced from \(WindowsNative.originName(record.originPlatform)). "
            + "Its audio stays on that device, so it cannot be played, opened or transcribed again here.")
        return true
    }
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
