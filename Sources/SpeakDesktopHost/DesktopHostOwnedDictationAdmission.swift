import Foundation
import SpeakCore
import SpeakDesktop

struct DesktopHostOwnedDictationStart<Platform: DesktopHostPlatform>: Sendable {
    let id: UUID
    let target: Platform.InsertionTarget?
    let deviceID: String
    let profile: DesktopProfileSession
    let textOutput: Task<Platform.TextOutputOptions, Never>
    let trigger: HotKeySessionTrigger
    let key: String
    let endpoint: String
    let configuration: DesktopConfiguration?
    var polish: DesktopHostLivePolishInput?
    var cleanup: DesktopHostCleanupInput?
}

struct DesktopHostOwnedDictationAdmission<Platform: DesktopHostPlatform>: Sendable {
    let snapshot: DesktopHostOwnedDictationStart<Platform>
    let operation: Task<Void, Never>
}

extension DesktopHostController {
    package var dictationSessionID: UUID? {
        recording?.record.id ?? ownedDictation?.id ?? ownedDictationAdmission?.snapshot.id
    }

    package var canStopDictationSession: Bool {
        hasOwnedDictation || (recording != nil && !busy)
    }

    /// Whether an owned (non-recording) dictation session is active or being
    /// admitted; `ownedDictation`/`ownedDictationAdmission` stay internal, so
    /// platform hosts outside this module read this instead.
    package var hasOwnedDictation: Bool {
        ownedDictation != nil || ownedDictationAdmission != nil
    }

    var dictationTrigger: HotKeySessionTrigger? {
        recording?.trigger ?? ownedDictation?.request.trigger ?? ownedDictationAdmission?.snapshot.trigger
    }

    package func dictationSessionReady() async -> Bool {
        guard !closed else { return false }
        if recording != nil { return true }
        guard let active = ownedDictation, active.stop == nil, active.abortReason == nil else { return false }
        let ready = await active.owner.readyForDictation
        return !closed && ownedDictation?.id == active.id && ownedDictation?.stop == nil
            && ownedDictation?.abortReason == nil && ready
    }

    // existing owned dictation-admission entry point; no behavior change.
    // swiftlint:disable:next function_parameter_count
    func ownedDictationStart(
        target: Platform.InsertionTarget?, deviceID: String, profile: DesktopProfileSession,
        textOutput: Task<Platform.TextOutputOptions, Never>, trigger: HotKeySessionTrigger,
        capability: DesktopHostOwnedDictationCapability, event: DesktopHostRecordingEvent<Platform>? = nil
    ) throws -> DesktopHostOwnedDictationStart<Platform> {
        let admission = DesktopPressCaptureAdmission(
            enabled: true, capability: capability.capability, permission: capability.permission, owner: .idle
        )
        if let refusal = admission.refusal {
            throw DesktopHostError(message: "Owned dictation unavailable: \(refusal)")
        }
        if let limitation = profile.blockingLimitation { throw DesktopHostError(message: limitation.message) }
        let key = try requireCredentialOrLocalModel(profile.modelIdentifier)
        try requireAzureResource(forLive: profile.modelIdentifier)
        let configuration: DesktopConfiguration?
        if let event { configuration = event.configuration } else { configuration = settings.configuration }
        return .init(
            id: UUID(), target: target, deviceID: deviceID,
            profile: profile.capturingTranscriptionOptions(
                profile.transcriptionOptions ?? configuration?.liveOptions ?? .desktopDefaults
            ),
            textOutput: textOutput, trigger: trigger, key: key, endpoint: azureResourceEndpoint(),
            // swiftlint:disable:next line_length
            configuration: configuration, polish: captureLivePolish(profile), cleanup: captureCleanup(profile.postProcessing)
        )
    }

    // existing owned dictation-admission overload; no behavior change.
    // swiftlint:disable:next function_parameter_count
    func admitOwnedDictation(
        target: Platform.InsertionTarget?, modelIndex: Int, deviceID: String,
        targetExecutablePath: String?, textOutput: Task<Platform.TextOutputOptions, Never>,
        trigger: HotKeySessionTrigger, wait: Bool
    ) async {
        await admitOwnedDictation(
            target: target, modelIndex: modelIndex, deviceID: deviceID,
            targetExecutablePath: targetExecutablePath, textOutput: textOutput,
            trigger: trigger, wait: wait, profile: nil
        )
    }

    // existing owned dictation-admission full entry point; no behavior change.
    // swiftlint:disable:next function_parameter_count
    func admitOwnedDictation(
        target: Platform.InsertionTarget?, modelIndex: Int, deviceID: String,
        targetExecutablePath: String?, textOutput: Task<Platform.TextOutputOptions, Never>,
        trigger: HotKeySessionTrigger, wait: Bool, profile: DesktopProfileSession?,
        event: DesktopHostRecordingEvent<Platform>? = nil
    ) async {
        guard isReady, !closed, !busy, recording == nil, ownedDictationAdmission == nil,
              let capability = ownedDictationCapability, DesktopHostModels.all.indices.contains(modelIndex) else {
            return
        }
        cancelOutput()
        guard selectModel(modelIndex) else { return }
        selectMicrophone(deviceID)
        do {
            let snapshot = try ownedDictationStart(
                target: target, deviceID: deviceID,
                profile: event?.profile ?? profile ?? resolvedProfile(executablePath: targetExecutablePath),
                textOutput: textOutput, trigger: trigger, capability: capability, event: event
            )
            cancellationRequested = false
            beginBusyOperation()
            let operation = Task { await self.performOwnedDictationAdmission(snapshot, capability: capability) }
            ownedDictationAdmission = .init(snapshot: snapshot, operation: operation)
            if wait {
                await withTaskCancellationHandler { await operation.value } onCancel: { operation.cancel() }
            }
        } catch {
            update(error.localizedDescription, state: 0)
            failHUDStart(error.localizedDescription)
        }
    }

    private func performOwnedDictationAdmission(
        _ snapshot: DesktopHostOwnedDictationStart<Platform>, capability: DesktopHostOwnedDictationCapability
    ) async {
        defer {
            if ownedDictationAdmission?.snapshot.id == snapshot.id { ownedDictationAdmission = nil }
            if Task.isCancelled { hotKeySession.startsAfter = ProcessInfo.processInfo.systemUptime }
            finishBusyOperation()
        }
        do {
            try Task.checkCancellation()
            try await playback.stopAndWait()
            try Task.checkCancellation()
            guard !closed else { throw CancellationError() }
            try await startOwnedDictation(snapshot, capability: capability)
            if Task.isCancelled, ownedDictation?.id == snapshot.id {
                await stopOwnedDictation(
                    requestID: snapshot.id, reason: "Recording startup cancelled. Audio retained."
                )
            }
        } catch {
            update(error.localizedDescription, state: 0)
            failHUDStart(error.localizedDescription)
        }
    }

    func stopOwnedDictationAdmission(wait: Bool, reason: String? = nil) async {
        let admission = ownedDictationAdmission
        if let active = ownedDictation {
            requestOwnedDictationStop(requestID: active.id, reason: reason)
            if wait { await ownedDictation?.stop?.value }
        } else if let admission {
            admission.operation.cancel()
        }
        if wait { await admission?.operation.value }
    }
}
