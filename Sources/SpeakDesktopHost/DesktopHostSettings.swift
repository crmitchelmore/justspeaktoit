import Foundation
import SpeakCore
import SpeakDesktop

extension DesktopHostController {
    package func selectedMicrophone() -> String { settings.microphoneDeviceID ?? "" }
    package func setMicrophoneWarning(_ warning: String?) { microphoneWarning = warning }

    package func selectMicrophone(_ identifier: String) {
        guard canUseHistory else { return }
        var changed = settings
        changed.microphoneDeviceID = identifier.isEmpty ? nil : identifier
        do {
            try JSONEncoder().encode(changed).write(
                to: directory.appendingPathComponent("settings.json"), options: .atomic
            )
            settings = changed
        } catch { update("Could not save the microphone choice: \(error.localizedDescription)") }
    }
}

/// Shortcut gesture bookkeeping, in the monotonic clock of recognition.
package struct DesktopHostHotKeySessionState: Sendable {
    package var lastDoubleTap: TimeInterval = -.infinity
    /// Starts recognised before this ended while a shortcut stop was finishing.
    package var startsAfter: TimeInterval = 0

    package init() {}
}

/// One recognised shortcut input with everything captured at its key press.
package struct DesktopHostShortcutRequest<Platform: DesktopHostPlatform>: Sendable {
    package let input: HotKeySessionPolicy.Input
    package let style: HotKeyActivationStyle
    /// Monotonic seconds when the gesture was recognised.
    package let recognisedAt: TimeInterval
    package let target: Platform.InsertionTarget?
    package let targetExecutablePath: String?
    package let textOutput: Task<Platform.TextOutputOptions, Never>
    package let modelIndex: Int
    package let deviceID: String

    package init(
        input: HotKeySessionPolicy.Input, style: HotKeyActivationStyle, recognisedAt: TimeInterval,
        target: Platform.InsertionTarget?, targetExecutablePath: String?,
        textOutput: Task<Platform.TextOutputOptions, Never>, modelIndex: Int, deviceID: String
    ) {
        self.input = input
        self.style = style
        self.recognisedAt = recognisedAt
        self.target = target
        self.targetExecutablePath = targetExecutablePath
        self.textOutput = textOutput
        self.modelIndex = modelIndex
        self.deviceID = deviceID
    }
}

extension DesktopHostController {
    /// Applies the shared macOS session rules to one recognised shortcut
    /// input: a gesture stops only the kind of session it started, and a start
    /// recognised while an earlier shortcut stop was still finishing is stale.
    package func shortcut(_ request: DesktopHostShortcutRequest<Platform>) async {
        guard !closed else { return }
        if case .gesture(.doubleTap) = request.input {
            let interval = request.recognisedAt - hotKeySession.lastDoubleTap
            guard interval >= HotKeyGestureTiming.doubleTapCommandInterval else { return }
            hotKeySession.lastDoubleTap = request.recognisedAt
        }
        guard let command = HotKeySessionPolicy.command(
            for: request.input, style: request.style, active: recording?.trigger
        ) else { return }
        switch command {
        case .start(let trigger):
            guard recording == nil, !busy, request.recognisedAt >= hotKeySession.startsAfter else { return }
            await toggle(
                target: request.target, modelIndex: request.modelIndex, deviceID: request.deviceID,
                targetExecutablePath: request.targetExecutablePath, textOutput: await request.textOutput.value,
                trigger: trigger
            )
        case .stop:
            guard recording != nil, !busy else { return }
            await toggle(
                target: request.target, modelIndex: request.modelIndex, deviceID: request.deviceID,
                targetExecutablePath: request.targetExecutablePath, textOutput: await request.textOutput.value
            )
            hotKeySession.startsAfter = ProcessInfo.processInfo.systemUptime
        }
    }
}

extension DesktopHostController {
    /// Ends Read aloud and every other playback request: the current segment
    /// stops through the shared controller, the segment being synthesized is
    /// cancelled and no later one is admitted, and a History start still
    /// resolving its audio never starts. The ended request reports nothing,
    /// because whatever ended it owns the status.
    package func stopReadAloud() {
        playbackRequests.end()
        Platform.stopReadAloud(&readAloudState, playback: playback)
    }

    package func hotKeySettings() -> Platform.HotKeySettings { settings.hotKey ?? Platform.defaultHotKey }
}
