import AppKit
import SpeakCore
import SwiftUI

struct CompleteStepView: View {
    @ObservedObject var state: OnboardingState
    @ObservedObject private var settings: AppSettings
    @Binding var isComplete: Bool

    init(state: OnboardingState, isComplete: Binding<Bool>) {
        self.state = state
        self.settings = state.settings
        self._isComplete = isComplete
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 20) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 80))
                    .foregroundColor(.green)

                Text("You're All Set!")
                    .font(.title)
                    .fontWeight(.bold)

                Text("\(ReleaseTrain.current.displayName) is ready to use")
                    .foregroundColor(.secondary)

                DiagnosticsConsentToggle(accessibilityIdentifier: "onboardingDiagnosticsConsentToggle")
                    .toggleStyle(.switch)
                    .frame(maxWidth: 440)

                if AppEnvironment.shared?.analyticsAvailable == true {
                    Toggle(
                        "Share anonymous analytics",
                        isOn: $settings.analyticsEnabled
                    )
                    .toggleStyle(.switch)
                    .font(.callout)
                    .frame(maxWidth: 440, minHeight: 44)
                    .accessibilityIdentifier("onboardingAnalyticsConsentToggle")
                    Text(
                        "Optional. Never includes transcripts, audio, prompts, clipboard text, "
                            + "keystrokes, API keys, screen content or personal identity. "
                            + "Sent to PostHog in the EU, which discards your IP address."
                    )
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
                }

                VStack(alignment: .leading, spacing: 16) {
                    TipRow(icon: "keyboard", text: state.settings.hasConfiguredGlobalHotKey
                        ? "Press \(state.selectedHotKey.displayString) to start recording"
                        : "Use the record button; assign an Alpha shortcut in Settings when ready")
                    TipRow(icon: "text.cursor", text: "Click in any text field, then record")
                    TipRow(icon: "gearshape.fill", text: "Click the menu bar icon for quick actions and Settings")
                }
                .padding(.horizontal, 40)
                .padding(.top, 20)

                Text("Tip: The app runs in your menu bar")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 10)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
        }
    }
}

struct TipRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(.accentColor)
                .frame(width: 30)

            Text(text)
                .font(.subheadline)
        }
    }
}

// MARK: - Preview

#if DEBUG
// Preview requires the full AppEnvironment to construct dependencies.
// Use the running app or SpeakHotKeysDemo for visual testing.
#endif
