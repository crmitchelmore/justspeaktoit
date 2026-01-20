import SwiftUI

/// Settings view for configuring keyboard shortcuts.
struct ShortcutsSettingsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @ObservedObject var shortcutManager: ShortcutManager

    @State private var selectedAction: ShortcutAction?

    var body: some View {
        LazyVStack(spacing: 20) {
            ShortcutSettingsCard(title: "Global Shortcuts", systemImage: "globe", tint: .brandLagoon) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("These shortcuts work system-wide, even when Speak is not focused.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ForEach(ShortcutAction.allCases.filter { $0.isGlobalByDefault }) { action in
                        shortcutRow(for: action)
                    }
                }
            }
            .speakTooltip("Configure shortcuts that work anywhere in macOS.")

            ShortcutSettingsCard(title: "App Shortcuts", systemImage: "app.badge", tint: .brandAccentWarm) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("These shortcuts only work when Speak is the active app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ForEach(ShortcutAction.allCases.filter { !$0.isGlobalByDefault }) { action in
                        shortcutRow(for: action)
                    }
                }
            }
            .speakTooltip("Configure shortcuts that work when Speak is focused.")

            if !shortcutManager.conflicts.isEmpty {
                ShortcutSettingsCard(title: "Conflicts", systemImage: "exclamationmark.triangle", tint: .red) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(shortcutManager.conflicts, id: \.action) { conflict in
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.red)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(conflict.action.displayName)
                                        .font(.subheadline.weight(.medium))
                                    Text(conflict.description)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }

            ShortcutSettingsCard(title: "Actions", systemImage: "arrow.counterclockwise", tint: .brandAccent) {
                HStack(spacing: 12) {
                    Button("Reset to Defaults") {
                        shortcutManager.resetToDefaults()
                    }
                    .buttonStyle(.bordered)
                    .speakTooltip("Restore all shortcuts to their original settings.")
                }
            }
        }
    }

    @ViewBuilder
    private func shortcutRow(for action: ShortcutAction) -> some View {
        let binding = shortcutManager.binding(for: action)
        let isRecording = shortcutManager.isRecordingShortcut && shortcutManager.recordingAction == action

        HStack(spacing: 12) {
            Toggle("", isOn: Binding(
                get: { binding.isEnabled },
                set: { shortcutManager.setEnabled($0, for: action) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)

            VStack(alignment: .leading, spacing: 2) {
                Text(action.displayName)
                    .font(.subheadline)
                    .foregroundStyle(binding.isEnabled ? .primary : .secondary)

                if action.isGlobalByDefault {
                    Toggle("Global", isOn: Binding(
                        get: { binding.isGlobal },
                        set: { shortcutManager.setGlobal($0, for: action) }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button {
                if isRecording {
                    shortcutManager.stopRecording()
                } else {
                    shortcutManager.startRecording(for: action)
                }
            } label: {
                if isRecording {
                    HStack(spacing: 4) {
                        Image(systemName: "keyboard")
                        Text("Press keys...")
                    }
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
                } else {
                    Text(binding.displayString)
                        .font(.system(.caption, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .buttonStyle(.plain)
            .speakTooltip("Click to record a new shortcut for this action.")
        }
        .padding(.vertical, 4)
        .opacity(binding.isEnabled ? 1.0 : 0.6)
    }
}

/// A styled card for shortcut settings.
private struct ShortcutSettingsCard<Content: View>: View {
    let title: String
    let systemImage: String
    let tint: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(tint.opacity(0.15))
                        .frame(width: 44, height: 44)
                    Image(systemName: systemImage)
                        .foregroundStyle(tint)
                        .font(.system(size: 20, weight: .semibold))
                }

                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
            }

            content
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(tint.opacity(0.12), lineWidth: 1)
                .allowsHitTesting(false)
        )
        .shadow(color: tint.opacity(0.08), radius: 18, x: 0, y: 12)
    }
}
