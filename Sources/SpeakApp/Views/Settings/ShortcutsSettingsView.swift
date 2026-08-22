import SpeakCore
import SwiftUI

/// Settings view for configuring keyboard shortcuts.
struct ShortcutsSettingsView: View {
    @Environment(\.appVisualDensity) private var density
    @ObservedObject var shortcutManager: ShortcutManager

    var body: some View {
        SpeakDensitySettingsSection(
            density: density,
            compactMinimumWidth: 460,
            maximumColumns: 2
        ) {
            ShortcutSettingsCard(title: "Global Shortcuts", systemImage: "globe", tint: .brandLagoon) {
                VStack(alignment: .leading, spacing: density.cardContentSpacing) {
                    Text("These shortcuts work system-wide, even when Speak is not focused.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    LazyVGrid(columns: shortcutColumns, alignment: .leading, spacing: density.inlineSpacing) {
                        ForEach(ShortcutAction.availableCases().filter { $0.isGlobalByDefault }) { action in
                            shortcutRow(for: action)
                        }
                    }
                }
            }
            .speakTooltip("Configure shortcuts that work anywhere in macOS.")

            ShortcutSettingsCard(title: "App Shortcuts", systemImage: "app.badge", tint: .brandAccentWarm) {
                VStack(alignment: .leading, spacing: density.cardContentSpacing) {
                    Text("These shortcuts only work when Speak is the active app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    LazyVGrid(columns: shortcutColumns, alignment: .leading, spacing: density.inlineSpacing) {
                        ForEach(ShortcutAction.availableCases().filter { !$0.isGlobalByDefault }) { action in
                            shortcutRow(for: action)
                        }
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

    private var shortcutColumns: [GridItem] {
        if density.isCompact {
            return [
                GridItem(
                    .adaptive(minimum: 220, maximum: 320),
                    spacing: density.inlineSpacing,
                    alignment: .top
                )
            ]
        }
        return [GridItem(.flexible(), alignment: .top)]
    }

    @ViewBuilder
    // swiftlint:disable:next function_body_length
    private func shortcutRow(for action: ShortcutAction) -> some View {
        let binding = shortcutManager.binding(for: action)
        let isRecording = shortcutManager.isRecordingShortcut && shortcutManager.recordingAction == action

        if density.isCompact {
            VStack(alignment: .leading, spacing: density.inlineSpacing) {
                HStack(spacing: density.inlineSpacing) {
                    Toggle("", isOn: Binding(
                        get: { binding.isEnabled },
                        set: { shortcutManager.setEnabled($0, for: action) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .accessibilityLabel("Enable \(action.displayName) shortcut")

                    Text(action.displayName)
                        .font(.caption)
                        .foregroundStyle(binding.isEnabled ? .primary : .secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    Spacer(minLength: 0)

                    if action.isGlobalByDefault {
                        Button {
                            shortcutManager.setGlobal(!binding.isGlobal, for: action)
                        } label: {
                            Image(systemName: binding.isGlobal ? "globe.americas.fill" : "globe.americas")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(binding.isGlobal ? Color.brandLagoon : .secondary)
                        .speakTooltip(binding.isGlobal ? "Make this shortcut app-only." : "Make this shortcut global.")
                        .accessibilityLabel(binding.isGlobal ? "Global shortcut" : "App-only shortcut")
                    }

                    shortcutRecorder(for: action, binding: binding, isRecording: isRecording)
                }

                if isRecording, let recordingError = shortcutManager.recordingError {
                    Label(recordingError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color.secondary.opacity(0.07),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .opacity(binding.isEnabled ? 1.0 : 0.6)
        } else {
            HStack(spacing: 12) {
                Toggle("", isOn: Binding(
                    get: { binding.isEnabled },
                    set: { shortcutManager.setEnabled($0, for: action) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel("Enable \(action.displayName) shortcut")

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

                shortcutRecorder(for: action, binding: binding, isRecording: isRecording)
            }
            .padding(.vertical, 4)
            .opacity(binding.isEnabled ? 1.0 : 0.6)

            if isRecording, let recordingError = shortcutManager.recordingError {
                Label(recordingError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func shortcutRecorder(
        for action: ShortcutAction,
        binding: KeyBinding,
        isRecording: Bool
    ) -> some View {
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
                .padding(.horizontal, density.isCompact ? 5 : 8)
                .padding(.vertical, density.isCompact ? 2 : 4)
                .background(Color.accentColor.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
            } else {
                Text(binding.displayString)
                    .font(.system(.caption, design: .monospaced))
                    .padding(.horizontal, density.isCompact ? 5 : 8)
                    .padding(.vertical, density.isCompact ? 2 : 4)
                    .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .buttonStyle(.plain)
        .speakTooltip("Click to record a new shortcut for this action.")
    }
}

/// A styled card for shortcut settings.
private struct ShortcutSettingsCard<Content: View>: View {
    let title: String
    let systemImage: String
    let tint: Color
    @ViewBuilder let content: Content

    var body: some View {
        SpeakDensityCard(
            title: title,
            systemImage: systemImage,
            tint: tint,
            regularCornerRadius: 26
        ) {
            content
        }
    }
}
