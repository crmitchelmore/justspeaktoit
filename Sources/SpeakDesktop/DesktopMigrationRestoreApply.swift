import Foundation
import SpeakCore

extension DesktopMigrationRestore {
    /// Points where apply checks for cancellation. Tests inject failures here.
    public enum Step: Equatable, Sendable {
        case profiles
        case history(Int)
        case finished
    }

    /// Applies a confirmed choice. Application data is compared with the
    /// preview first; profiles and History are rolled back on any failure.
    /// Run on an owned cancellable off-actor worker, not a settings queue.
    public static func apply(
        _ plan: Plan, choice: Choice, targets: Targets,
        checkpoint: @escaping @Sendable (Step) throws -> Void = { _ in try Task.checkCancellation() }
    ) async -> Outcome {
        let computed: Computed
        do {
            try Task.checkCancellation()
            guard try await currentBaseline(targets) == plan.baseline else {
                return .stale("History or app profiles changed after the preview. Nothing was restored; "
                    + "choose Restore backup again to see a new preview.")
            }
            let guards = try await targets.history.migrationRestoreGuards()
            computed = try compute(
                plan.incoming, baseline: plan.baseline, choice: choice, guards: guards, digests: targets.digests
            )
        } catch is CancellationError {
            return .cancelled(restored: true, "Restore was cancelled. Nothing was changed.")
        } catch {
            return .failed(restored: true, "Restore failed before writing. Nothing was changed. "
                + error.localizedDescription)
        }
        var profileRollback: Data??
        do {
            if let profiles = computed.profiles {
                let document = try profileDocument(profiles)
                try checkpoint(.profiles)
                profileRollback = .some(plan.baseline.profileDocument)
                try FileManager.default.createDirectory(
                    at: targets.profiles.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try document.write(to: targets.profiles.fileURL, options: .atomic)
            }
            let written = try await targets.history.applyMigrationRestore(computed.history, checkpoint: checkpoint)
            return .applied(Applied(
                choice: choice, history: written, profilesChanged: computed.profiles != nil, preview: plan.preview
            ))
        } catch {
            var failures = (error as? DesktopMigrationRestoreWriteError)?.rollbackFailures ?? []
            let underlying = (error as? DesktopMigrationRestoreWriteError)?.underlying ?? error
            if let prior = profileRollback {
                do {
                    if let prior {
                        try prior.write(to: targets.profiles.fileURL, options: .atomic)
                    } else if FileManager.default.fileExists(atPath: targets.profiles.fileURL.path) {
                        try FileManager.default.removeItem(at: targets.profiles.fileURL)
                    }
                } catch {
                    failures.append("app profiles (\(error.localizedDescription))")
                }
            }
            let restored = failures.isEmpty
            let state = restored
                ? "Everything was put back as it was."
                : "Rollback could not restore: " + failures.joined(separator: "; ") + "."
            if underlying is CancellationError {
                return .cancelled(restored: restored, "Restore was cancelled. " + state)
            }
            return .failed(restored: restored, "Restore failed: \(underlying.localizedDescription) " + state)
        }
    }
}
