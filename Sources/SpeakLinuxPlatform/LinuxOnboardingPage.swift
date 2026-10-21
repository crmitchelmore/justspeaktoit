import SpeakCore

/// Passive presentation only; native actions remain in the Linux host.
package struct LinuxOnboardingPage: Sendable {
    package let step: DesktopOnboardingStep

    package init(_ step: DesktopOnboardingStep) { self.step = step }

    package var index: Int32 { Int32(step.position - 1) }
    package var title: String { step.title }
    package var progress: String { step.progress }
    package var hasPrevious: Bool { step.previous != nil }
    package var isLast: Bool { step.next == nil }
    package var actions: [DesktopOnboardingAction] { step.actions.filter { $0 != .testDictation } }

    package var detail: String {
        guard step == .textInsertion else { return step.detail }
        return "X11 can paste into the captured app. Wayland depends on your compositor's RemoteDesktop portal; "
            + "when insertion is unavailable, text is copied for manual paste. No access is granted by this guide."
    }

    package func title(for action: DesktopOnboardingAction) -> String {
        action == .openMicrophoneSettings ? "Check microphone permissions..." : action.title
    }
}
