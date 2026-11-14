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

extension DesktopHostController where Platform: DesktopHostReadAloudPlatform {
    /// The native restore entry: settings, vocabulary and connections are
    /// restored, and API keys only when `nativeFlags` has the opt-in (8).
    package func beginMigrationRestore(_ source: URL, nativeFlags: Int) {
        guard (0...15).contains(nativeFlags) else {
            update("Could not restore backup: the restore selection is invalid. Nothing was changed.")
            return
        }
        beginMigrationRestore(
            source, configuration: migrationRestoreSource(includeCredentials: nativeFlags & 8 != 0)
        )
    }
}

extension DesktopHostController {
    /// Admission only: reading, validation and the preview run on an owned
    /// cancellable worker, never on the settings queue. Nothing is written.
    /// Without `configuration` settings and API keys are left out of the restore.
    package func beginMigrationRestore(
        _ source: URL, using restorer: DesktopHostMigrationRestorer? = nil,
        configuration: DesktopMigrationRestore.ConfigurationSource? = nil
    ) {
        guard !closed else { return }
        guard canUseHistory, migrationWork.restoreTask == nil, migrationWork.restoreConfirmation == nil,
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
        let targets = DesktopMigrationRestore.Targets(
            history: store, profiles: profileStore, digests: restorer.digests, configuration: configuration
        )
        let worker = Task.detached {
            await DesktopMigrationRestore.prepare(source, reader: restorer.reader, targets: targets)
        }
        migrationWork.restoreWorker = worker
        migrationWork.restoreTask = Task {
            let preparation = await worker.value
            defer {
                migrationWork.restoreWorker = nil
                migrationWork.restoreTask = nil
                busy = false
                finishOperation()
            }
            guard !closed else {
                if case let .ready(plan) = preparation { DesktopMigrationRestore.discard(plan) }
                return
            }
            switch preparation {
            case let .ready(plan):
                presentMigrationRestore(plan, restorer: restorer, configuration: configuration)
            case .cancelled:
                showSelectedHistory(status: "Restore cancelled. Nothing was changed.", state: 0)
            case let .failed(message):
                showSelectedHistory(status: "Could not read backup: \(message) Nothing was changed.", state: 0)
            }
        }
    }

    private func presentMigrationRestore(
        _ plan: DesktopMigrationRestore.Plan, restorer: DesktopHostMigrationRestorer,
        configuration: DesktopMigrationRestore.ConfigurationSource?
    ) {
        let preview = plan.preview
        guard preview.changes(.merge) || preview.changes(.replace) else {
            DesktopMigrationRestore.discard(plan)
            let declined = preview.credentialsDeclined
                ? " To restore its API keys, restore again and choose to include them." : ""
            showSelectedHistory(
                status: "This backup has nothing new to restore here. Nothing was changed.\(declined)", state: 0
            )
            return
        }
        let id = UUID()
        migrationWork.restoreConfirmation = .init(id: id, plan: plan, configuration: configuration)
        do {
            try restorer.confirm(id.uuidString, preview.text, preview.offersReplace)
            update("Review the restore preview. Nothing has been written yet.", state: 0)
        } catch {
            migrationWork.restoreConfirmation = nil
            DesktopMigrationRestore.discard(plan)
            showSelectedHistory(status: "Could not show the restore preview: \(error.localizedDescription)", state: 0)
        }
    }

    /// `choice` is 0 to cancel, 1 to merge or 2 to replace profiles. Only the
    /// current token can apply, and only once.
    package func answerMigrationRestore(
        _ identifier: String, choice: Int, using restorer: DesktopHostMigrationRestorer? = nil
    ) {
        guard !closed else { return }
        guard let confirmation = migrationWork.restoreConfirmation,
              UUID(uuidString: identifier) == confirmation.id else {
            update("That restore preview is no longer current. Nothing was changed.")
            return
        }
        migrationWork.restoreConfirmation = nil
        guard let selected = DesktopMigrationRestore.Choice(rawValue: choice) else {
            DesktopMigrationRestore.discard(confirmation.plan)
            update("Restore cancelled. Nothing was changed.")
            return
        }
        guard selected == .merge || confirmation.plan.preview.offersReplace else {
            DesktopMigrationRestore.discard(confirmation.plan)
            update("Restore cancelled because Replace was not offered. Nothing was changed.")
            return
        }
        guard canUseHistory, migrationWork.restoreTask == nil,
              let restorer = restorer ?? Platform.migrationRestorer else {
            DesktopMigrationRestore.discard(confirmation.plan)
            update("Restore cancelled because another operation started. Nothing was changed.")
            return
        }
        busy = true
        cancellationRequested = false
        activeOperations += 1
        update("Restoring backup... Changes are rolled back if anything fails.", state: 2)
        let targets = DesktopMigrationRestore.Targets(
            history: store, profiles: profileStore, digests: restorer.digests,
            configuration: confirmation.configuration
        )
        let plan = confirmation.plan
        let worker = Task.detached {
            await DesktopMigrationRestore.apply(plan, choice: selected, targets: targets)
        }
        migrationWork.restoreApplyWorker = worker
        migrationWork.restoreTask = Task {
            let outcome = await worker.value
            defer {
                migrationWork.restoreApplyWorker = nil
                migrationWork.restoreTask = nil
                busy = false
                finishOperation()
            }
            guard !closed else { return }
            await finishMigrationRestore(outcome)
        }
    }

    private func finishMigrationRestore(_ outcome: DesktopMigrationRestore.Outcome) async {
        switch outcome {
        case let .applied(applied):
            if applied.profilesChanged { reloadRestoredProfiles() }
            if applied.vocabularyChanged { await reloadRestoredVocabulary() }
            for record in applied.history { indexHistory(record) }
            refreshHistory()
            showSelectedHistory(status: Self.migrationRestoreStatus(applied), state: 0)
        case let .stale(message):
            showSelectedHistory(status: message, state: 0)
        case let .cancelled(restored, message), let .failed(restored, message):
            if !restored { reloadRestoredProfiles() }
            await reloadRestoredVocabulary()
            refreshHistory()
            showSelectedHistory(status: message, state: 0)
        }
    }

    static func migrationRestoreStatus(_ applied: DesktopMigrationRestore.Applied) -> String {
        var parts = ["\(applied.history.count) History item(s) written"]
        if applied.audio > 0 { parts.append("\(applied.audio) recording(s) attached") }
        if applied.profilesChanged { parts.append("app profiles updated") }
        if applied.vocabularyChanged { parts.append("vocabulary updated") }
        if applied.settingsChanged { parts.append("settings updated") }
        if applied.credentials > 0 { parts.append("\(applied.credentials) API key(s) saved") }
        return "Restore finished: " + parts.joined(separator: ", ") + "."
    }

    /// Reloads the vocabulary editor's store from disk so it cannot write back
    /// the lists a restore just replaced or rolled back.
    private func reloadRestoredVocabulary() async {
        guard let task = vocabularyLoad, let vocabulary = try? await task.value else { return }
        do { try await vocabulary.reload() } catch { vocabularyLoad = nil }
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
