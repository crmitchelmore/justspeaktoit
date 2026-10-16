import Foundation
import SpeakCore
import SpeakDesktop

private struct DesktopHostRecordingRequest<Platform: DesktopHostPlatform>: Sendable {
    let target: Platform.InsertionTarget?
    let modelIndex: Int
    let deviceID: String
    let executablePath: String?
    let textOutput: Platform.TextOutputOptions
    let trigger: HotKeySessionTrigger
    let profile: DesktopProfileSession?
    let waitForOwnedStartup: Bool
    let event: DesktopHostRecordingEvent<Platform>?
}

extension DesktopHostController {
    /// `textOutput` was read in settings order at the Record event, so a later
    /// Apply cannot change how this recording is output.
    package func toggle(
        target: Platform.InsertionTarget?, modelIndex: Int, deviceID: String,
        targetExecutablePath: String?, textOutput: Platform.TextOutputOptions,
        trigger: HotKeySessionTrigger = .other
    ) async {
        await toggleRecording(.init(
            target: target, modelIndex: modelIndex, deviceID: deviceID, executablePath: targetExecutablePath,
            textOutput: textOutput, trigger: trigger, profile: nil, waitForOwnedStartup: true, event: nil
        ))
    }

    package func toggleCaptured(
        target: Platform.InsertionTarget?, modelIndex: Int, deviceID: String,
        textOutput: Platform.TextOutputOptions, profile: DesktopProfileSession,
        trigger: HotKeySessionTrigger = .other
    ) async {
        await toggleRecording(.init(
            target: target, modelIndex: modelIndex, deviceID: deviceID, executablePath: nil,
            textOutput: textOutput, trigger: trigger, profile: profile, waitForOwnedStartup: true, event: nil
        ))
    }

    package func admitCaptured(
        target: Platform.InsertionTarget?, modelIndex: Int, deviceID: String,
        textOutput: Platform.TextOutputOptions, profile: DesktopProfileSession,
        trigger: HotKeySessionTrigger = .other
    ) async {
        await toggleRecording(.init(
            target: target, modelIndex: modelIndex, deviceID: deviceID, executablePath: nil,
            textOutput: textOutput, trigger: trigger, profile: profile, waitForOwnedStartup: false, event: nil
        ))
    }

    package func toggleCaptured(
        _ event: DesktopHostRecordingEvent<Platform>, target: Platform.InsertionTarget?,
        modelIndex: Int, deviceID: String, trigger: HotKeySessionTrigger = .other
    ) async {
        await toggleRecording(.init(
            target: target, modelIndex: modelIndex, deviceID: deviceID, executablePath: nil,
            textOutput: event.textOutput, trigger: trigger, profile: event.profile,
            waitForOwnedStartup: true, event: event
        ))
    }

    private func toggleRecording(_ request: DesktopHostRecordingRequest<Platform>) async {
        if !closed, ownedDictation != nil || ownedDictationAdmission != nil {
            await stopOwnedDictationAdmission(wait: request.waitForOwnedStartup)
            return
        }
        if handsFreeMachine.isArmed { await disarmHandsFree(); return }
        if ownedDictationCapability != nil {
            await admitOwnedDictation(
                target: request.target, modelIndex: request.modelIndex, deviceID: request.deviceID,
                targetExecutablePath: request.executablePath, textOutput: Task { request.textOutput },
                trigger: request.trigger, wait: request.waitForOwnedStartup, profile: request.profile,
                event: request.event
            )
            return
        }
        guard isReady, !busy, !closed, DesktopHostModels.all.indices.contains(request.modelIndex) else { return }
        cancelOutput()
        let selected = selectModel(request.modelIndex)
        selectMicrophone(request.deviceID)
        beginBusyOperation()
        defer { finishBusyOperation() }
        if recording != nil { await stopAndTranscribe(); return }
        // Never record with a model other than the one chosen; why it could
        // not be saved stays shown.
        guard selected else { return }
        cancellationRequested = false
        do {
            // Wait for acknowledged silence, while slow decoder release stays
            // off this actor. Busy prevents another capture during suspension.
            try await playback.stopAndWait()
            guard !closed else { return }
            let profile = request.profile ?? resolvedProfile(executablePath: request.executablePath)
            if let limitation = profile.blockingLimitation { throw DesktopHostError(message: limitation.message) }
            try await startRecording(.init(
                target: request.target, deviceID: request.deviceID, profile: profile,
                textOutput: request.textOutput, trigger: request.trigger, handsFree: nil,
                capturePolicy: request.event.map { DesktopHostCapturePolicy(configuration: $0.configuration) }
            ))
        } catch {
            update(error.localizedDescription, state: 0)
            failHUDStart(error.localizedDescription)
        }
    }
}
