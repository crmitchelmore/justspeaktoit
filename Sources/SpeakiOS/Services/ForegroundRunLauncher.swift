#if os(iOS)
import AVFoundation
import Foundation
import SpeakCore

/// The provider side of starting a foreground run: the credential wait, the
/// run's request and route, and the session it starts. Each step returns what
/// the coordinator then publishes, so no published state is written here.
@MainActor
struct ForegroundRunLauncher {
    struct Request {
        let usesBatch: Bool
        let modelID: String
    }

    let owner: ForegroundRunOwner
    let observation: ForegroundRunObservation
    let audioSessionManager: AudioSessionManager
    let ensureKeysLoaded: @MainActor () async -> Void
    let networkSnapshot: CaptureNetworkPathMonitor.SnapshotProvider
    let localRecognitionCapability: @MainActor (String) -> AppleLocalRecognitionCapability
    /// The concrete test seam; the coordinator's `makeSession` injects any session (#936).
    let sessionFactory: (() throws -> IOSTranscriptionSession)?

    /// Waits for the initial keychain load, so auto-start on a cold launch
    /// doesn't read empty API keys and fall back to Apple Speech.
    func request(for runID: UUID) async throws -> Request {
        await ensureKeysLoaded()
        try owner.checkStart(runID)
        observation.note(.stage(.credentialsReady), run: runID)
        let settings = AppSettings.shared
        let usesBatch = settings.transcriptionMode == .batch
        let modelID = usesBatch ? settings.batchTranscriptionModel : settings.selectedModel
        return Request(usesBatch: usesBatch, modelID: modelID)
    }

    /// Batch runs need usable credentials before anything else is published.
    func requireCredentials(for request: Request) throws {
        guard request.usesBatch else { return }
        try AppSettings.shared.requireAvailableCredentials(for: request.modelID, purpose: .batchTranscription)
    }

    func route(for request: Request) throws -> ForegroundCaptureRoute {
        try ForegroundCaptureRoute.resolve(
            settings: AppSettings.shared, requestedModelID: request.modelID, usesBatch: request.usesBatch,
            connectivity: networkSnapshot(), localCapability: localRecognitionCapability
        )
    }

    /// The route's session, unless the concrete test seam supplies one.
    func makeSession(_ route: ForegroundCaptureRoute, request: Request) throws -> any IOSRecordingSession {
        try sessionFactory?() ?? route.makeSession(
            usesBatch: request.usesBatch, settings: AppSettings.shared, audioSessionManager: audioSessionManager
        )
    }

    /// Starts this run's bound session. Cancellation is installed for exactly
    /// this run and session before it starts; activation follows the startup
    /// operation's final cancellation check.
    func start(
        _ session: any IOSRecordingSession, run runID: UUID, defaultSession: Bool,
        preRollBuffers: [AVAudioPCMBuffer], analyzerFallbackAllowed: Bool
    ) async throws {
        try owner.adoptStarting(session, run: runID)
        observation.observe(session.resolution, run: runID, defaultSession: defaultSession && sessionFactory == nil)
        try await session.start(preRollBuffers: preRollBuffers, analyzerFallbackAllowed: analyzerFallbackAllowed)
        try owner.checkStart(runID)
        observation.note(.stage(.sessionStarted), run: runID)
        owner.noteStarted(session)
    }
}
#endif
