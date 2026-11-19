import AppKit
import SpeakCore
import SpeakHotKeys
import SwiftUI

// MARK: - Hotkey Step

struct HotKeyStepView: View {
    @ObservedObject var state: OnboardingState
    private var isFnSelected: Bool { state.hotKeyWasChosen && state.selectedHotKey == .fnKey }
    private var isCustomSelected: Bool { state.hotKeyWasChosen && state.selectedHotKey != .fnKey }

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "keyboard.fill")
                .font(.system(size: 50))
                .foregroundColor(.accentColor)

            Text("Choose Your Hotkey")
                .font(.title)
                .fontWeight(.bold)

            Text(ReleaseTrain.current == .alpha
                ? "Optional: choose a different shortcut from Stable, or continue without one"
                : "This is the key you'll press to start and stop recording")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 16) {
                // Fn key option
                Button {
                    state.selectedHotKey = .fnKey
                    state.hotKeyWasChosen = true
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("🌐")
                                    .font(.title2)
                                Text("Fn (Globe) Key")
                                    .font(.headline)
                            }
                            Text("Default — works on most Mac keyboards")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if isFnSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.title2)
                        }
                    }
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(isFnSelected ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.1))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(isFnSelected ? Color.accentColor : Color.clear, lineWidth: 2)
                    )
                }
                .buttonStyle(.plain)

                // Custom shortcut option
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Custom Shortcut")
                                .font(.headline)
                            Text("Choose any key combination")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if isCustomSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.title2)
                        }
                    }

                    HotKeyRecorder("Record shortcut", hotKey: $state.selectedHotKey)
                        .onChange(of: state.selectedHotKey) { _, _ in state.hotKeyWasChosen = true }
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isCustomSelected ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.1))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(isCustomSelected ? Color.accentColor : Color.clear, lineWidth: 2)
                )
            }
            .padding(.horizontal, 40)

            // Troubleshooting
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 8) {
                    TroubleshootingRow(
                        icon: "globe",
                        text: "If Fn opens emoji picker: go to System Settings → Keyboard → "
                            + "\"Press 🌐 key to\" and change it to \"Do Nothing\""
                    )
                    TroubleshootingRow(
                        icon: "keyboard",
                        text: "External keyboards may not send Fn events — use a custom shortcut instead"
                    )
                    TroubleshootingRow(
                        icon: "lock.shield",
                        text: "Input Monitoring enables Fn. Accessibility enables typing into other apps."
                    )
                }
                .padding(.top, 8)
            } label: {
                Text("Having trouble with Fn?")
                    .font(.caption)
                    .foregroundColor(.accentColor)
            }
            .padding(.horizontal, 40)
        }
    }
}

struct TroubleshootingRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 16)
            Text(text)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}
