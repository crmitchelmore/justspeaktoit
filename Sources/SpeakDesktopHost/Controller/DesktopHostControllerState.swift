import Foundation
import SpeakCore
import SpeakDesktop

// Domain state the host actor owns. Each value is read and written only on the
// actor; grouping keeps related fields together without changing who owns them.

/// Background model-catalogue discovery and the revision that retires stale results.
struct DesktopHostModelDiscoveryState {
    var task: Task<Void, Never>?
    var catalogRevision: UInt64 = 0
}

/// Correction learning: the observation in progress, its consent and the
/// revision that retires a superseded observation.
struct DesktopHostCorrectionLearningState {
    var observation: DesktopCorrectionObservation?
    var observationTask: Task<Void, Never>?
    var observationWait: @Sendable (Double) async throws -> Void = {
        try await Task.sleep(for: .seconds($0))
    }
    var revision: UInt64 = 0
    var approved = false
    var observationalConsent = false
    var notice: String?
}

/// Live-connection pre-warming: approval, the generation that retires stale
/// probes, the warmed-host tracker, the captured target and the one probe in flight.
struct DesktopHostConnectionWarmState {
    var approved = false
    var generation = UUID()
    var tracker = LiveStreamWarmTracker()
    var capture: DesktopHostConnectionWarmCapture?
    var task: (id: UUID, task: Task<Void, Never>)?
    var pending = false
    var credentialWork = 0
}

/// Migration export, inspection and restore: each visible task and the worker it awaits.
struct DesktopHostMigrationWork {
    var exportTask: Task<Void, Never>?
    var exportWorker: Task<DesktopMigrationBackup.Outcome, Never>?
    var inspectionTask: Task<Void, Never>?
    var inspectionWorker: Task<DesktopMigrationInspection.Outcome, Never>?
    var restoreTask: Task<Void, Never>?
    var restoreWorker: Task<DesktopMigrationRestore.Preparation, Never>?
    var restoreApplyWorker: Task<DesktopMigrationRestore.Outcome, Never>?
    var restoreConfirmation: (id: UUID, plan: DesktopMigrationRestore.Plan)?
}

/// Voice Output and provider API-key work. Each in-flight operation keeps its
/// identity, destination and task in one value, so cancelling or settling it
/// clears them together. The selection epoch retires requests made for an
/// earlier voice selection. The account and synthesis worker counters stay on
/// the controller: they count work this state does not own.
package struct DesktopHostVoiceCredentialState {
    /// The Voice key read the window last asked for.
    package struct ReadRequest: Equatable {
        package let id: UUID
        package let destination: VoiceOutputCredentialDestination

        package init(id: UUID, destination: VoiceOutputCredentialDestination) {
            self.id = id
            self.destination = destination
        }
    }

    /// The read in flight. It may read for an older request than `readRequest`;
    /// when it settles it hands over to the newer one.
    package struct ReadWorker {
        package let destination: VoiceOutputCredentialDestination
        package let task: Task<Void, Never>

        package init(destination: VoiceOutputCredentialDestination, task: Task<Void, Never>) {
            self.destination = destination
            self.task = task
        }
    }

    /// The one Voice key write: its request, destination and task.
    package struct Write {
        package let id: UUID
        package let destination: VoiceOutputCredentialDestination
        package let task: Task<Void, Never>

        package init(id: UUID, destination: VoiceOutputCredentialDestination, task: Task<Void, Never>) {
            self.id = id
            self.destination = destination
            self.task = task
        }
    }

    /// Provider key edits applied from Settings: the one in flight, those
    /// queued behind it in order, its status line, and whether shutdown
    /// stopped editing for good.
    struct ProviderEdits {
        var task: Task<Void, Never>?
        var pending: [DesktopHostCredentialEdit] = []
        var status = ""
        var stopped = false
    }

    package var selectionEpoch = UUID()
    package var readRequest: ReadRequest?
    package var readWorker: ReadWorker?
    package var write: Write?
    /// The provider slot the last account read issued; a save must match it.
    package var issuedProviderSlot: VoiceOutputCredentialSlot?
    /// The provider API-key write in flight. It holds the credential store
    /// until the native call returns, even after cancellation.
    package var providerWriteTask: Task<Void, Error>?
    var providerEdits = ProviderEdits()

    package init() {}

    /// A Voice or provider key write owns the credential store.
    package var isWriting: Bool { write != nil || providerWriteTask != nil }

    /// Cancels the read in flight and forgets the request.
    package mutating func cancelRead() {
        readWorker?.task.cancel()
        readRequest = nil
    }

    /// Cancels the write for `requestID`; false when it is not the pending write.
    package func cancelWrite(_ requestID: UUID) -> Bool {
        guard let write, write.id == requestID else { return false }
        write.task.cancel()
        return true
    }

    /// Cancels every read and write aimed at `destination`.
    package mutating func cancelWork(for destination: VoiceOutputCredentialDestination) {
        if readWorker?.destination == destination { readWorker?.task.cancel() }
        if readRequest?.destination == destination { readRequest = nil }
        if write?.destination == destination { write?.task.cancel() }
    }

    /// Stops provider key editing for good: queued edits are dropped and the
    /// edit and write in flight are cancelled.
    package mutating func stopProviderEdits() {
        providerEdits.stopped = true
        providerEdits.pending.removeAll()
        providerEdits.task?.cancel()
        providerWriteTask?.cancel()
    }
}
