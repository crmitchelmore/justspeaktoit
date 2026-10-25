import SpeakCore

/// Passive presentation only; native actions remain in the Linux host.
package struct LinuxOnboardingPage: Sendable {
    package enum Destination: Equatable, Sendable {
        case permissions, apiKeys, general, transcription, keyboard, postProcessing
    }

    package let step: DesktopOnboardingStep

    package init(_ step: DesktopOnboardingStep) { self.step = step }

    package var index: Int32 { Int32(step.position - 1) }
    package var title: String { step.title }
    package var progress: String { step.progress }
    package var hasPrevious: Bool { step.previous != nil }
    package var isLast: Bool { step.next == nil }
    package var actions: [DesktopOnboardingAction] { step.actions.filter { Self.destination(for: $0) != nil } }

    package static func destination(for action: DesktopOnboardingAction) -> Destination? {
        switch action {
        case .openPermissions, .openMicrophoneSettings: return .permissions
        case .chooseRemoteProvider: return .apiKeys
        case .chooseMicrophone, .chooseTextOutput: return .general
        case .downloadLocalModel: return .transcription
        case .chooseShortcut: return .keyboard
        case .openPostProcessing: return .postProcessing
        case .testDictation: return nil
        }
    }

    package var detail: String {
        guard step == .textInsertion else { return step.detail }
        return "X11 can paste into the captured app. Wayland depends on your compositor's RemoteDesktop portal; "
            + "when insertion is unavailable, text is copied for manual paste. No access is granted by this guide."
    }

    package func title(for action: DesktopOnboardingAction) -> String {
        action == .openMicrophoneSettings ? "Check microphone permissions..." : action.title
    }
}
