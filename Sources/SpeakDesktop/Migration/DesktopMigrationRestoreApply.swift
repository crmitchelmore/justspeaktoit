import Foundation
import SpeakCore

extension DesktopMigrationRestore {
    struct StaleHistory: LocalizedError {
        var errorDescription: String? { "History changed after the preview." }
    }
    struct StaleProfiles: LocalizedError {
        var errorDescription: String? { "App profiles changed after the preview." }
    }
    struct StaleVocabulary: LocalizedError {
        var errorDescription: String? { "Vocabulary changed after the preview." }
    }
    static let staleMessage = "Something this restore changes was edited after the preview. Nothing was restored; "
        + "choose Restore backup again to see a new preview."

    /// Points where apply checks for cancellation. Tests inject failures here.
    public enum Step: Equatable, Sendable {
        case vocabulary
        case configuration
        case profiles
        case history(Int)
        case finished
    }

    /// Applies a confirmed choice. Application data is compared with the
    /// preview first; vocabulary, settings, API keys, profiles, History and
    /// audio are rolled back on any failure. The plan's staging is removed.
    /// Run on an owned cancellable off-actor worker, not a settings queue.
    public static func apply(
        _ plan: Plan, choice: Choice, targets: Targets,
        checkpoint: @escaping @Sendable (Step) throws -> Void = { _ in try Task.checkCancellation() }
    ) async -> Outcome {
        defer { discard(plan) }
        let computed: Computed
        do {
            guard let current = try await recompute(plan, choice: choice, targets: targets) else {
                return .stale(staleMessage)
            }
            computed = current
        } catch is CancellationError {
            return .cancelled(restored: true, "Restore was cancelled. Nothing was changed.")
        } catch {
            return .failed(restored: true, "Restore failed before writing. Nothing was changed. "
                + error.localizedDescription)
        }
        var vocabularyWritten: [VocabularyWrite] = []
        var undo: ConfigurationUndo?
        do {
            let document = try computed.profiles.map(profileDocument)
            try writeVocabulary(computed.vocabulary, root: targets.appDirectory, checkpoint: checkpoint) {
                vocabularyWritten.append($0)
            }
            try checkpoint(.configuration)
            let write = computed.configurationWrite
            if !write.isEmpty, let source = targets.configuration {
                undo = try await source.write(write)
            }
            let written = try await targets.history.applyMigrationRestore(
                computed.history, expectedHistory: plan.baseline.history, digests: targets.digests,
                profileTransaction: .init(
                    store: targets.profiles, expected: plan.baseline.profileDocument, replacement: document
                ),
                checkpoint: checkpoint
            )
            return .applied(computed.applied(choice: choice, history: written, preview: plan.preview))
        } catch {
            var failures = (error as? DesktopMigrationRestoreWriteError)?.rollbackFailures ?? []
            if let undo {
                do { try await undo() } catch {
                    failures.append("settings or API keys (\(error.localizedDescription))")
                }
            }
            failures += rollbackVocabulary(vocabularyWritten, root: targets.appDirectory)
            return failedOutcome(error, rollbackFailures: failures)
        }
    }

    /// Recomputes the confirmed choice, or nil when this device changed since the preview.
    private static func recompute(_ plan: Plan, choice: Choice, targets: Targets) async throws -> Computed? {
        try Task.checkCancellation()
        let configuration = try await targets.configuration?.read()
        guard try await currentBaseline(targets, incoming: plan.incoming, configuration: configuration)
            == plan.baseline else {
            return nil
        }
        let guards = try await targets.history.migrationRestoreGuards()
        return try compute(
            plan.incoming, baseline: plan.baseline, choice: choice, guards: guards, digests: targets.digests,
            configuration: configuration
        )
    }

    private static func failedOutcome(_ error: Error, rollbackFailures failures: [String]) -> Outcome {
        let underlying = (error as? DesktopMigrationRestoreWriteError)?.underlying ?? error
        let restored = failures.isEmpty
        if (underlying is StaleHistory || underlying is StaleProfiles || underlying is StaleVocabulary)
            && restored {
            return .stale(staleMessage)
        }
        let state = restored
            ? "Everything was put back as it was."
            : "Rollback could not restore: " + failures.joined(separator: "; ") + "."
        if underlying is CancellationError {
            return .cancelled(restored: restored, "Restore was cancelled. " + state)
        }
        return .failed(restored: restored, "Restore failed: \(underlying.localizedDescription) " + state)
    }

    /// Each store is rechecked against its preview bytes just before it is replaced.
    private static func writeVocabulary(
        _ writes: [VocabularyWrite], root: URL, checkpoint: @Sendable (Step) throws -> Void,
        written: (VocabularyWrite) -> Void
    ) throws {
        for write in writes {
            try checkpoint(.vocabulary)
            let current = try DesktopVocabularyMigrationSource.read(
                write.path, root: root.standardizedFileURL, checkCancellation: { try Task.checkCancellation() }
            )
            guard current == write.prior else { throw StaleVocabulary() }
            let url = root.appendingPathComponent(write.path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            written(write)
            try write.data.write(to: url, options: .atomic)
        }
    }

    private static func rollbackVocabulary(_ written: [VocabularyWrite], root: URL) -> [String] {
        var failures: [String] = []
        for write in written.reversed() {
            let url = root.appendingPathComponent(write.path)
            do {
                if let prior = write.prior {
                    try prior.write(to: url, options: .atomic)
                } else if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            } catch {
                failures.append("vocabulary \(write.path) (\(error.localizedDescription))")
            }
        }
        return failures
    }
}

extension DesktopMigrationRestore.Computed {
    func applied(
        choice: DesktopMigrationRestore.Choice, history: [DesktopRecordingStore.Record],
        preview: DesktopMigrationRestore.Preview
    ) -> DesktopMigrationRestore.Applied {
        var applied = DesktopMigrationRestore.Applied(
            choice: choice, history: history, profilesChanged: profiles != nil, preview: preview
        )
        applied.audio = self.history.filter { $0.audio != nil }.count
        applied.vocabularyChanged = !vocabulary.isEmpty
        applied.settingsChanged = preferences != nil
        applied.credentials = credentials.count
        return applied
    }
}
