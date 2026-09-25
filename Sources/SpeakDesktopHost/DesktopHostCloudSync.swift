import Foundation
import SpeakCore
import SpeakDesktop
import SpeakDesktopSync
import SpeakSync

/// The native pieces a host supplies around the shared iCloud sync flow.
package struct DesktopHostCloudSyncNative: Sendable {
    /// Written as `originPlatform` on recordings made on this host.
    package var originPlatform: String
    /// Where the user chooses what syncs, ending "Choose what to sync …".
    package var settingsLocation: String
    /// Hands the iCloud sync settings their state. Called only while sync
    /// runs, never after `stop()` has returned.
    package var present: @Sendable (DesktopCloudSyncStatus) -> Void
    /// Starts listening on the loopback callback port, for one sign-in.
    package var listen: @Sendable (UInt16) throws -> any DesktopLoopbackListener
    /// Opens Apple's sign-in page, already checked as trusted, in the default browser.
    package var openSignInPage: @Sendable (URL) throws -> Void

    package init(
        originPlatform: String,
        settingsLocation: String,
        present: @escaping @Sendable (DesktopCloudSyncStatus) -> Void,
        listen: @escaping @Sendable (UInt16) throws -> any DesktopLoopbackListener,
        openSignInPage: @escaping @Sendable (URL) throws -> Void
    ) {
        self.originPlatform = originPlatform
        self.settingsLocation = settingsLocation
        self.present = present
        self.listen = listen
        self.openSignInPage = openSignInPage
    }
}

/// How often sync runs and how long it waits.
package struct DesktopHostCloudSyncTiming: Sendable {
    /// Between periodic passes; web clients get no change notifications.
    package var interval: Duration = .seconds(300)
    /// How long the loopback callback listens for the browser.
    package var signInWindow: Duration = .seconds(600)
    /// How long shutdown waits for sync work that is still running.
    package var shutdownGrace: Duration = .seconds(3)

    package static let standard = DesktopHostCloudSyncTiming()

    package init() {}
}

/// iCloud sync for a host's window: the iCloud sync settings' actions, the
/// loopback Apple ID sign-in, and a periodic pass. Nothing syncs until the
/// user signs in and chooses History or key import. Windows and Linux run
/// this same flow and differ only in `DesktopHostCloudSyncNative`.
///
/// Every task it starts belongs to `work`. Shutdown stops that first, so no
/// sync request or settings action starts anything afterwards, no status line
/// or settings state reaches the window, History changes are no longer shown
/// and no browser sign-in starts; it then waits a bounded time for the
/// cancelled work to end.
package final class DesktopHostCloudSync<Platform: DesktopHostPlatform>: @unchecked Sendable {
    /// What the user asked for in the iCloud sync settings.
    package enum Action: Sendable {
        /// The choices as shown when Apply was pressed, and the typed
        /// passphrase ("" when none).
        case apply(history: Bool, keys: Bool, passphrase: String)
        case signIn
        case signOut
        case syncNow
    }

    package let service: DesktopCloudSyncService
    private let work: DesktopCloudSyncWork
    private let native: DesktopHostCloudSyncNative
    private let timing: DesktopHostCloudSyncTiming
    private let lock = NSLock()
    private var signIn: Task<Void, Never>?

    /// Where a host's sync state lives: cursors, the bound iCloud user,
    /// acknowledgements and imported-key bookkeeping. No credentials.
    package static func stateURL(in directory: URL) -> URL {
        directory.appendingPathComponent("CloudSync").appendingPathComponent("state.json")
    }

    package init(
        controller: DesktopHostController<Platform>,
        resolution: DesktopCloudSyncConfiguration.Resolution,
        transport: any CloudKitWebServicesHTTPTransport,
        vault: any DesktopCredentialVault,
        cryptography: any SyncEnvelopeCryptography,
        native: DesktopHostCloudSyncNative,
        timing: DesktopHostCloudSyncTiming = .standard
    ) throws {
        let state = try DesktopCloudSyncStateStore(url: Self.stateURL(in: controller.directory))
        let work = DesktopCloudSyncWork()
        self.work = work
        self.native = native
        self.timing = timing
        let history = DesktopHistorySyncStore(
            records: controller.store,
            state: state,
            origin: native.originPlatform,
            onChanges: { changes in
                // Changes already saved; once shutdown begins they are not shown.
                guard !work.isStopped else { return }
                await controller.applySyncedHistory(changes)
            }
        )
        service = DesktopCloudSyncService(
            resolution: resolution,
            transport: transport,
            vault: vault,
            state: state,
            historyStore: history,
            cryptography: cryptography
        )
    }

    /// Reads the stored session, connects the controller, shows the settings'
    /// state and starts the periodic pass, the first one at once.
    package func start(controller: DesktopHostController<Platform>) async {
        await service.prepare()
        await controller.installCloudSync(DesktopHostSyncHooks(
            historyChanged: { [weak self] in self?.requestSync() },
            saveKeyByHand: { [service] value, identifier in
                try await service.saveKeyByHand(value, identifier: identifier)
            }
        ))
        await publish()
        let interval = timing.interval
        work.start { [weak self] in
            while !Task.isCancelled {
                await self?.runSync(announce: false)
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Refuses new work and cancels what runs, which it returns for `drain`.
    /// Once this returns, nothing more reaches the window.
    package func stop() -> [Task<Void, Never>] {
        let running = work.stop()
        lock.withLock { signIn = nil }
        return running
    }

    /// Waits for stopped work to end, at most `shutdownGrace`.
    package func drain(_ running: [Task<Void, Never>]) async {
        let grace = timing.shutdownGrace
        await DesktopCloudSyncWork.drain(running) { try? await Task.sleep(for: grace) }
    }

    /// A local History change: sync soon. The service serialises passes and a
    /// change during a pass runs one follow-up pass.
    package func requestSync() {
        work.start { [weak self] in await self?.runSync(announce: false) }
    }

    // MARK: - Settings actions (from the UI thread)

    package func handle(_ action: Action) {
        switch action {
        case .apply(let history, let keys, let passphrase):
            work.start { [weak self] in await self?.apply(history: history, keys: keys, passphrase: passphrase) }
        case .signIn:
            // A new sign-in replaces one in progress, whose listener closes
            // before the new one takes the callback port.
            let previous = lock.withLock { signIn }
            guard let task = work.start({ [weak self] in
                await previous?.value
                await self?.performSignIn()
            }) else { return }
            let replaced = lock.withLock { () -> Task<Void, Never>? in
                defer { signIn = task }
                return signIn
            }
            replaced?.cancel()
        case .signOut: work.start { [weak self] in await self?.signOut() }
        case .syncNow: work.start { [weak self] in await self?.runSync(announce: true) }
        }
    }

    /// The settings' choices, applied as the user's latest intent: a typed
    /// passphrase always turns key import on, and an unticked box always turns
    /// it off, so an earlier Apply still in progress cannot decide the result.
    private func apply(history: Bool, keys: Bool, passphrase: String) async {
        do {
            try await service.setHistoryEnabled(history)
            let importing = await service.status().apiKeyImportEnabled
            if keys, !passphrase.isEmpty {
                let report = try await service.enableKeyImport(passphrase: passphrase)
                notify(Self.describe(imported: report.importedKeys))
            } else if keys, !importing {
                notify("Enter the API-key sync passphrase from your Mac to import its keys.")
                await publish()
                return
            } else if !keys {
                try await service.disableKeyImport()
            }
            await runSync(announce: !keys || importing)
        } catch DesktopCloudSyncError.keyImportSuperseded {
            // A later Apply changed key import and reports for itself.
            await publish()
        } catch {
            notify("iCloud sync: \(error.localizedDescription)")
            await publish()
        }
    }

    private func signOut() async {
        do {
            try await service.signOut()
            let device = Platform.localDeviceName
            notify("Signed out of iCloud on \(device). History and saved keys stay on \(device).")
        } catch { notify("iCloud sign-out: \(error.localizedDescription)") }
        await publish()
    }

    private func runSync(announce: Bool) async {
        let report = await service.sync()
        if let error = report.error {
            if announce { notify("iCloud sync: \(error)") }
        } else if !report.importedKeys.isEmpty {
            notify(Self.describe(imported: report.importedKeys))
        } else if announce {
            let summary = await service.status().summary
            notify(summary)
        }
        await publish()
    }

    /// Shows a status line, unless shutdown has begun.
    private func notify(_ message: String) {
        work.ifRunning { Platform.update(message) }
    }

    // MARK: - Sign-in

    /// Opens Apple's sign-in page and waits for its redirect to the loopback
    /// callback registered on the container's API token.
    private func performSignIn() async {
        do {
            guard let page = try await service.signInPage() else {
                notify("Already signed in to iCloud.")
                await runSync(announce: true)
                return
            }
            let listener = try native.listen(DesktopCloudSyncSignIn.callbackPort)
            defer { listener.close() }
            // Checked just before opening, so closing the window does not
            // start a browser sign-in. The desktop may wait on other windows,
            // so no lock is held while it opens the page.
            guard !work.isStopped, !Task.isCancelled else { return }
            try native.openSignInPage(page)
            notify("Finish signing in with your Apple ID in your browser.")
            let token = try await DesktopCloudSyncSignIn.awaitCallback(on: listener, within: timing.signInWindow)
            try Task.checkCancellation()
            try await service.completeSignIn(webAuthToken: token)
            notify("Signed in to iCloud. Choose what to sync \(native.settingsLocation).")
            await runSync(announce: false)
        } catch is CancellationError {
            return
        } catch {
            notify("iCloud sign-in did not finish: \(error.localizedDescription)")
        }
        await publish()
    }

    // MARK: - Settings state

    /// Hands the settings their state. Done while sync runs, so it cannot
    /// reach the window after shutdown detached it.
    private func publish() async {
        let status = await service.status()
        work.ifRunning { native.present(status) }
    }

    /// Names the providers whose keys were imported, for the status line.
    package static func describe(imported identifiers: [String]) -> String {
        guard !identifiers.isEmpty else { return "No new API keys to import from your Mac." }
        let providers = DesktopHostModels.all.compactMap { DesktopHostModels.provider(for: $0.id) }
        let names = identifiers.sorted().map { identifier in
            providers.first { $0.apiKeyIdentifier == identifier }?.displayName ?? identifier
        }
        return "Imported API keys from your Mac: \(names.joined(separator: ", "))."
    }
}

extension DesktopHostController {
    package func installCloudSync(_ hooks: DesktopHostSyncHooks) {
        cloudSync = hooks
    }

    /// Shows History changes that sync has already saved. Rows update at once;
    /// the displayed transcript is re-rendered only for the selected record and
    /// only while nothing else owns the transcript area. A removed selection is
    /// cleared, so no action can target a record that no longer exists.
    package func applySyncedHistory(_ changes: [DesktopHistorySyncChange]) async {
        guard !closed else { return }
        var selectedChanged = false
        for change in changes {
            switch change {
            case .saved(let id):
                guard let record = await store.existingRecord(id: id) else { continue }
                // Reading the record suspends; the window may have closed meanwhile.
                guard !closed else { return }
                indexHistory(record)
                selectedChanged = selectedChanged || id == selectedHistoryID
            case .removed(let id):
                history[id] = nil
                historySearchText[id] = nil
                if id == selectedHistoryID {
                    playback.stop(announcing: false)
                    stopReadAloud()
                    selectedHistoryID = nil
                    transcript = ""
                    transcriptVariant = .processed
                    Platform.transcriptVariant(nil, for: nil, switchable: false)
                    update("The selected recording was deleted on another device.", transcript: "")
                }
            case .keptAfterRemoteDeletion:
                continue
            }
        }
        refreshHistory()
        if selectedChanged, canUseHistory, let id = selectedHistoryID, let record = history[id] {
            transcript = record.text(for: transcriptVariant) ?? ""
            Platform.historyPresentation(record, variant: transcriptVariant, status: "Updated from iCloud.")
        }
    }
}
