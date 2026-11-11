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
