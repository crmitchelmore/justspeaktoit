import Foundation
import SpeakCore
import SpeakDesktop

/// Platform hooks for restoring a Mac-compatible backup. `confirm` shows the
/// preview and must answer through `answerMigrationRestore` with the same token.
package struct DesktopHostMigrationRestorer: Sendable {
    let reader: DesktopMigrationInspection.Reader
    let digests: LocalModelDigestProvider
    let confirm: @Sendable (_ token: String, _ text: String, _ offersReplace: Bool) throws -> Void

    package init(
        reader: DesktopMigrationInspection.Reader, digests: LocalModelDigestProvider,
        confirm: @escaping @Sendable (_ token: String, _ text: String, _ offersReplace: Bool) throws -> Void
    ) {
        self.reader = reader
        self.digests = digests
        self.confirm = confirm
    }
}

extension DesktopHostPlatform {
    package static var migrationRestorer: DesktopHostMigrationRestorer? { nil }
}

extension DesktopHostController {
    /// Admission only: reading, validation and the preview run on an owned
    /// cancellable worker, never on the settings queue. Nothing is written.
    package func beginMigrationRestore(_ source: URL, using restorer: DesktopHostMigrationRestorer? = nil) {
        guard !closed else { return }
        guard canUseHistory, migrationRestoreTask == nil, migrationRestoreConfirmation == nil,
              audioCleanupConfirmation == nil else {
            update("Restore is unavailable while another operation or confirmation is running.")
            return
        }
        guard let restorer = restorer ?? Platform.migrationRestorer else {
            update("Restoring a backup is unavailable on this host.")
            return
        }
        busy = true
        cancellationRequested = false
        activeOperations += 1
        update("Reading backup... Nothing will change until you confirm.", state: 2)
        let targets = DesktopMigrationRestore.Targets(history: store, profiles: profileStore, digests: restorer.digests)
        let worker = Task.detached {
            await DesktopMigrationRestore.prepare(source, reader: restorer.reader, targets: targets)
        }
        migrationRestoreWorker = worker
        migrationRestoreTask = Task {
            let preparation = await worker.value
            defer {
                migrationRestoreWorker = nil
                migrationRestoreTask = nil
                busy = false
                finishOperation()
            }
            guard !closed else { return }
            switch preparation {
            case let .ready(plan):
                presentMigrationRestore(plan, restorer: restorer)
            case .cancelled:
                showSelectedHistory(status: "Restore cancelled. Nothing was changed.", state: 0)
            case let .failed(message):
                showSelectedHistory(status: "Could not read backup: \(message) Nothing was changed.", state: 0)
            }
        }
    }

    private func presentMigrationRestore(_ plan: DesktopMigrationRestore.Plan, restorer: DesktopHostMigrationRestorer) {
        let preview = plan.preview
        guard preview.changes(.merge) || preview.changes(.replace) else {
            showSelectedHistory(status: "This backup has nothing new to restore here. Nothing was changed.", state: 0)
            return
        }
        let id = UUID()
        migrationRestoreConfirmation = (id, plan)
        do {
            try restorer.confirm(id.uuidString, preview.text, preview.offersReplace)
            update("Review the restore preview. Nothing has been written yet.", state: 0)
        } catch {
            migrationRestoreConfirmation = nil
            showSelectedHistory(status: "Could not show the restore preview: \(error.localizedDescription)", state: 0)
        }
    }

    /// `choice` is 0 to cancel, 1 to merge or 2 to replace profiles. Only the
    /// current token can apply, and only once.
    package func answerMigrationRestore(
        _ identifier: String, choice: Int, using restorer: DesktopHostMigrationRestorer? = nil
    ) {
        guard !closed else { return }
        guard let confirmation = migrationRestoreConfirmation,
              UUID(uuidString: identifier) == confirmation.id else {
            update("That restore preview is no longer current. Nothing was changed.")
            return
        }
        migrationRestoreConfirmation = nil
        guard let selected = DesktopMigrationRestore.Choice(rawValue: choice) else {
            update("Restore cancelled. Nothing was changed.")
            return
        }
        guard selected == .merge || confirmation.plan.preview.offersReplace else {
            update("Restore cancelled because Replace was not offered. Nothing was changed.")
            return
        }
        guard canUseHistory, migrationRestoreTask == nil,
              let restorer = restorer ?? Platform.migrationRestorer else {
            update("Restore cancelled because another operation started. Nothing was changed.")
            return
        }
        busy = true
        cancellationRequested = false
        activeOperations += 1
        update("Restoring backup... Changes are rolled back if anything fails.", state: 2)
        let targets = DesktopMigrationRestore.Targets(history: store, profiles: profileStore, digests: restorer.digests)
        let plan = confirmation.plan
        let worker = Task.detached {
            await DesktopMigrationRestore.apply(plan, choice: selected, targets: targets)
        }
        migrationRestoreApplyWorker = worker
        migrationRestoreTask = Task {
            let outcome = await worker.value
            defer {
                migrationRestoreApplyWorker = nil
                migrationRestoreTask = nil
                busy = false
                finishOperation()
            }
            guard !closed else { return }
            finishMigrationRestore(outcome)
        }
    }

    private func finishMigrationRestore(_ outcome: DesktopMigrationRestore.Outcome) {
        switch outcome {
        case let .applied(applied):
            if applied.profilesChanged { reloadRestoredProfiles() }
            for record in applied.history { indexHistory(record) }
            refreshHistory()
            let restored = applied.history.count
            let profileText = applied.profilesChanged ? " App profiles were updated." : ""
            showSelectedHistory(
                status: "Restore finished: \(restored) History item(s) written.\(profileText) "
                    + "Settings, audio and credentials were not applied.",
                state: 0
            )
        case let .stale(message):
            showSelectedHistory(status: message, state: 0)
        case let .cancelled(restored, message), let .failed(restored, message):
            if !restored { reloadRestoredProfiles() }
            refreshHistory()
            showSelectedHistory(status: message, state: 0)
        }
    }

    private func reloadRestoredProfiles() {
        profileEditorState = nil
        do {
            let loaded = try Self.loadProfiles(from: profileStore)
            profiles = loaded.profiles
            profileWarning = loaded.warning
        } catch {
            profileWarning = "Restored app profiles could not be reloaded: \(error.localizedDescription)"
        }
    }
}
