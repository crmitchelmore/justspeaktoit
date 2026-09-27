import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost
import SpeakDesktopSync
import SpeakLinuxPlatform
import SpeakSync
import CLinuxSupport

/// iCloud sync for the window: the iCloud sync group, the loopback Apple ID
/// sign-in and a periodic pass, over the same CloudKit Web Services service,
/// container and callback URL as Windows. Nothing syncs until the user signs
/// in and chooses History or key import; importing the Mac's API keys also
/// needs its passphrase.
///
/// Every task it starts belongs to `work`. Shutdown stops that first, so no
/// sync request or group action starts anything afterwards and nothing more
/// reaches the window; it then waits a bounded time for the cancelled work.
final class LinuxCloudSync: @unchecked Sendable {
    static let interval: Duration = .seconds(300)
    static let signInWindow: Duration = .seconds(600)
    static let shutdownGrace: Duration = .seconds(3)

    let service: DesktopCloudSyncService
    private let work: DesktopCloudSyncWork
    private let lock = NSLock()
    private var signIn: Task<Void, Never>?

    init(controller: LinuxAppController, directory: URL) throws {
        let resolution = DesktopCloudSyncConfiguration.resolve(
            buildToken: CloudKitWebBuildConfiguration.apiToken,
            buildEnvironment: CloudKitWebBuildConfiguration.environment,
            processEnvironment: ProcessInfo.processInfo.environment
        )
        let state = try DesktopCloudSyncStateStore(
            url: directory.appendingPathComponent("CloudSync").appendingPathComponent("state.json")
        )
        let work = DesktopCloudSyncWork()
        self.work = work
        let history = DesktopHistorySyncStore(
            records: controller.store,
            state: state,
            onChanges: { changes in
                // Changes already saved; once shutdown begins they are not shown.
                guard !work.isStopped else { return }
                await controller.applySyncedHistory(changes)
            }
        )
        service = DesktopCloudSyncService(
            resolution: resolution,
            transport: URLSessionCloudKitWebServicesTransport(),
            vault: LinuxCredentialVault(),
            state: state,
            historyStore: history,
            cryptography: LinuxEnvelopeCryptography()
        )
    }

    /// Creates sync for a running (not smoke-test) window and shows its state.
    static func configure(_ holder: LinuxEventContext) async {
        guard !holder.smokeTest else {
            _ = jsti_window_set_cloud_sync("iCloud sync is not used in the smoke test.", 0, 0, 0, 0)
            return
        }
        do {
            try LinuxFiles.preparePrivateDirectory(holder.controller.directory.appendingPathComponent("CloudSync"))
            let sync = try LinuxCloudSync(controller: holder.controller, directory: holder.controller.directory)
            holder.cloudSync = sync
            await sync.start(controller: holder.controller)
        } catch {
            _ = jsti_window_set_cloud_sync("iCloud sync could not start: \(error.localizedDescription)", 0, 0, 0, 0)
        }
    }

    /// Stops sync before the window's context is released.
    static func shutDown(_ holder: LinuxEventContext) async {
        let running = holder.cloudSync?.stop() ?? []
        await DesktopCloudSyncWork.drain(running) { try? await Task.sleep(for: Self.shutdownGrace) }
    }

    private func start(controller: LinuxAppController) async {
        await service.prepare()
        await controller.installCloudSync(DesktopHostSyncHooks(
            historyChanged: { [weak self] in self?.requestSync() },
            saveKeyByHand: { [service] value, identifier in
                try await service.saveKeyByHand(value, identifier: identifier)
            }
        ))
        await publish()
        work.start { [weak self] in
            while !Task.isCancelled {
                await self?.runSync(announce: false)
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    private func stop() -> [Task<Void, Never>] {
        let running = work.stop()
        lock.withLock { signIn = nil }
        return running
    }

    /// A local History change: sync soon. The service serialises passes.
    func requestSync() {
        work.start { [weak self] in await self?.runSync(announce: false) }
    }

    // MARK: - Group actions (from the GTK thread)

    func handle(action: Int, history: Bool, keys: Bool, passphrase: String) {
        switch action {
        case 1: work.start { [weak self] in await self?.apply(history: history, keys: keys, passphrase: passphrase) }
        case 2:
            guard let task = work.start({ [weak self] in await self?.performSignIn() }) else { return }
            let previous = lock.withLock { () -> Task<Void, Never>? in
                defer { signIn = task }
                return signIn
            }
            previous?.cancel()
        case 3: work.start { [weak self] in await self?.signOut() }
        case 4: work.start { [weak self] in await self?.runSync(announce: true) }
        default: break
        }
    }

    /// The group's choices, applied as the user's latest intent: a typed
    /// passphrase turns key import on, and an unticked switch turns it off.
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
            await publish()
        } catch {
            notify("iCloud sync: \(error.localizedDescription)")
            await publish()
        }
    }

    private func signOut() async {
        do {
            try await service.signOut()
            notify("Signed out of iCloud on this computer. History and saved keys stay here.")
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

    private func notify(_ message: String) {
        work.ifRunning { LinuxHostPlatform.update(message) }
    }

    // MARK: - Sign-in

    /// Opens Apple's sign-in page and waits for its redirect to the loopback
    /// callback (`DesktopCloudSyncSignIn.callbackURL`, shared with Windows).
    private func performSignIn() async {
        do {
            guard let page = try await service.signInPage() else {
                notify("Already signed in to iCloud.")
                await runSync(announce: true)
                return
            }
            let listener = try LinuxLoopbackListener(port: DesktopCloudSyncSignIn.callbackPort)
            defer { listener.close() }
            // Checked just before opening, so closing the window does not start a browser sign-in.
            guard !work.isStopped, !Task.isCancelled else { return }
            try LinuxNative.call { jsti_open_uri(page.absoluteString, $0, $1) }
            notify("Finish signing in with your Apple ID in your browser.")
            let token = try await LinuxCloudSyncSignIn.awaitCallback(on: listener, window: Self.signInWindow)
            try Task.checkCancellation()
            try await service.completeSignIn(webAuthToken: token)
            notify("Signed in to iCloud. Choose what to sync under iCloud sync, then Apply.")
            await runSync(announce: false)
        } catch is CancellationError {
            return
        } catch {
            notify("iCloud sign-in did not finish: \(error.localizedDescription)")
        }
        await publish()
    }

    // MARK: - Group state

    private func publish() async {
        let status = await service.status()
        work.ifRunning {
            _ = jsti_window_set_cloud_sync(
                status.summary, status.unavailableReason == nil ? 1 : 0, status.isSignedIn ? 1 : 0,
                status.historyEnabled ? 1 : 0, status.apiKeyImportEnabled ? 1 : 0
            )
        }
    }

    static func describe(imported identifiers: [String]) -> String {
        guard !identifiers.isEmpty else { return "No new API keys to import from your Mac." }
        let providers = DesktopHostModels.all.compactMap { DesktopHostModels.provider(for: $0.id) }
        let names = identifiers.sorted().map { identifier in
            providers.first { $0.apiKeyIdentifier == identifier }?.displayName ?? identifier
        }
        return "Imported API keys from your Mac: \(names.joined(separator: ", "))."
    }
}
