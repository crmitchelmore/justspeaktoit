import Foundation
import SpeakCore
import SpeakDesktop

extension DesktopHostController where Platform: DesktopHostReadAloudPlatform {
    package func voiceUsageSnapshot(
        access: DesktopVoiceUsageReadAccess, digests: LocalModelDigestProvider
    ) async throws -> DesktopVoiceUsageSnapshot {
        guard !closed else { throw CancellationError() }
        guard !voiceUsage.collecting else { throw DesktopVoiceUsageSnapshot.Failure.stillClosing }
        voiceUsage.collecting = true
        activeOperations += 1
        defer {
            voiceUsage.collecting = false
            finishOperation()
        }
        let revision = voiceUsage.revision
        let epoch = voiceUsage.epoch
        let captures = voiceUsage.active.filter { $0.value.epoch == epoch }
        let observations = captures.mapValues { $0.capture.records }
        let memory = DesktopVoiceUsageSnapshot.Memory(
            loadedRecords: voiceUsage.records, unsavedRecords: voiceUsage.unsaved,
            activeCaptures: observations.keys.sorted { $0.uuidString < $1.uuidString }.map {
                .init(records: observations[$0] ?? [])
            },
            loadFailed: voiceUsage.loadFailed, warning: voiceUsage.warning,
            omittedUnsavedObservations: voiceUsage.omittedUnsavedObservations,
            unsavedProblem: voiceUsage.unsavedProblem
        )
        let directory = directory
        let worker = Task.detached(priority: .utility) {
            try DesktopVoiceUsageSnapshot.collect(
                appDirectory: directory, memory: memory, access: access, digests: digests)
        }
        let snapshot = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        guard voiceUsage.revision == revision, voiceUsage.epoch == epoch,
              captures.allSatisfy({ $0.value.capture.records == observations[$0.key] }) else {
            throw DesktopVoiceUsageSnapshot.Failure.stateChanged
        }
        return snapshot
    }
}
