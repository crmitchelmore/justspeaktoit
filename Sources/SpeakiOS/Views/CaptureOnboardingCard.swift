#if os(iOS)
import SpeakCore
import SwiftUI
import UIKit

extension CaptureHardwareProfile {
    /// What this device can actually be set up with. Nothing here claims the
    /// user has done any setup — that is `CaptureOnboardingState.provenTriggers`.
    static func current() -> CaptureHardwareProfile {
        let identifier = Self.deviceIdentifier()
        var supportsControls = false
        if #available(iOS 18.0, *) { supportsControls = true }
        return CaptureHardwareProfile(
            hasActionButton: ActionButtonHardware.hasActionButton(deviceIdentifier: identifier),
            supportsNativeControls: supportsControls,
            // Back Tap on iPhone, Apple Pencil squeeze on iPad, Siri on both.
            supportsShortcutGestures: true,
            supportsKeyboardExtension: true
        )
    }

    /// `uname`'s machine string, or the simulated model when running in the
    /// simulator (where `uname` reports the host architecture).
    static func deviceIdentifier() -> String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }
        var info = utsname()
        uname(&info)
        let machine = info.machine
        return withUnsafePointer(to: machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: machine)) {
                String(cString: $0)
            }
        }
    }
}

/// A single, dismissible suggestion for a trigger the user has not proved yet.
///
/// It deliberately carries no setup steps: the instructions live once, in
/// `HardwareTriggerSettingsView` and `KeyboardSetupView`, and this card only
/// says why the trigger is worth having and takes the user there.
struct CaptureOnboardingCard: View {
    let trigger: CaptureTrigger
    let hasActionButton: Bool
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: self.symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(self.title)
                    .font(.subheadline.weight(.semibold))
                Text(self.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                NavigationLink {
                    self.destination
                } label: {
                    Text("Show me how")
                        .font(.footnote.weight(.semibold))
                }
                .accessibilityIdentifier("onboardingCardSetUpLink")
            }
            Spacer(minLength: 0)
            Button(action: self.onDismiss) {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss suggestion")
            .accessibilityIdentifier("onboardingCardDismissButton")
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityIdentifier("onboardingCard")
    }

    @ViewBuilder
    private var destination: some View {
        switch self.trigger {
        case .keyboard: KeyboardSetupView()
        default: HardwareTriggerSettingsView(settings: AppSettings.shared)
        }
    }

    private var symbol: String {
        switch self.trigger {
        case .control: self.hasActionButton ? "button.programmable" : "square.grid.2x2.fill"
        case .shortcut: "hand.tap.fill"
        case .keyboard: "keyboard.badge.ellipsis"
        case .inApp: "mic.fill"
        }
    }

    private var title: String {
        switch self.trigger {
        case .control: self.hasActionButton ? "Record without opening the app" : "Record from Control Centre"
        case .shortcut: "Record with a gesture"
        case .keyboard: "Dictate straight into any app"
        case .inApp: "Record in the app"
        }
    }

    private var detail: String {
        switch self.trigger {
        case .control:
            self.hasActionButton
                ? "Put the Transcribe Voice control on your Action Button, in Control Centre or on the Lock Screen."
                : "Put the Transcribe Voice control in Control Centre or on the Lock Screen."
        case .shortcut:
            "Back Tap, Siri or an Apple Pencil squeeze can start a recording without touching the app."
        case .keyboard:
            "Add the Just Speak keyboard and tap the mic key in any text field."
        case .inApp:
            "Tap the microphone button."
        }
    }
}
#endif
