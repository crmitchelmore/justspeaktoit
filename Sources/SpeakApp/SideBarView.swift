import SwiftUI

enum SidebarItem: Hashable, Identifiable {
  case dashboard
  case history
  case voiceOutput
  case corrections
  case troubleshooting
  case settings(SettingsTab)

  var id: Self { self }

  var label: LocalizedStringKey {
    LocalizedStringKey(title(isAssemblyAI: false))
  }

  func title(isAssemblyAI: Bool) -> String {
    switch self {
    case .dashboard:
      return "Dashboard"
    case .history:
      return "History"
    case .voiceOutput:
      return "Voice Output"
    case .corrections:
      return "Corrections"
    case .troubleshooting:
      return "Troubleshooting"
    case .settings(let tab):
      return tab.title(isAssemblyAI: isAssemblyAI)
    }
  }

  var systemImage: String {
    switch self {
    case .dashboard:
      return "waveform"
    case .history:
      return "clock"
    case .voiceOutput:
      return "speaker.wave.3"
    case .corrections:
      return "character.book.closed"
    case .troubleshooting:
      return "stethoscope"
    case .settings(let tab):
      return tab.systemImage
    }
  }

  var color: Color {
    switch self {
    case .dashboard:
      return .brandLagoon
    case .history:
      return .brandAccent
    case .voiceOutput:
      return .green
    case .corrections:
      return .brandAccentWarm
    case .troubleshooting:
      return .brandLagoon
    case .settings:
      return .brandAccentWarm
    }
  }

  var helpMessage: String {
    switch self {
    case .dashboard:
      return "Open the dashboard for live stats, quick actions, and your most recent session."
    case .history:
      return "Review every past recording with transcripts, costs, and network details."
    case .voiceOutput:
      return "Convert text to natural speech with various voices and providers."
    case .corrections:
      return "Curate custom name and phrase corrections that stay private to your device."
    case .troubleshooting:
      return "Diagnose common issues, view quick fixes, and get help with configuration."
    case .settings(let tab):
      return "Adjust \(tab.title) preferences."
    }
  }

  var shortcutAction: ShortcutAction {
    switch self {
    case .dashboard:
      return .openDashboard
    case .history:
      return .showHistory
    case .voiceOutput:
      return .openVoiceOutput
    case .corrections:
      return .openCorrections
    case .troubleshooting:
      return .openTroubleshooting
    case .settings(let tab):
      return tab.shortcutAction
    }
  }
}

struct SideBarView: View {
  @Binding var selection: SidebarItem?
  @EnvironmentObject private var settings: AppSettings
  @EnvironmentObject private var shortcutManager: ShortcutManager

  var body: some View {
    List {
      Section("Speak") {
        ForEach([SidebarItem.dashboard, .history, .voiceOutput, .corrections, .troubleshooting]) { item in
          Button {
            selection = item
          } label: {
            HStack(spacing: 12) {
              Image(systemName: item.systemImage)
                .foregroundStyle(item.color)
                .imageScale(.medium)
                .frame(width: 20)
              Text(item.title(isAssemblyAI: settings.isAssemblyAIModel))
                .fontWeight(selection == item ? .semibold : .regular)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(2)
                .frame(maxWidth: .infinity, alignment: .leading)
              shortcutHint(for: item)
                .layoutPriority(0)
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .focusable(true)
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .background(
            selection == item
              ? RoundedRectangle(cornerRadius: 8)
                .fill(item.color.opacity(0.15))
              : nil
          )
          .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
          .listRowBackground(Color.clear)
          .speakTooltip(item.helpMessage)
          .accessibilityLabel(item.title(isAssemblyAI: settings.isAssemblyAIModel))
          .accessibilityHint(accessibilityHint(for: item))
        }
      }

      Section("Settings") {
        ForEach(SettingsTab.allCases) { tab in
          let item = SidebarItem.settings(tab)
          Button {
            selection = item
          } label: {
            HStack(spacing: 12) {
              Image(systemName: tab.systemImage)
                .foregroundStyle(Color.brandAccentWarm)
                .imageScale(.medium)
                .frame(width: 20)
              Text(LocalizedStringKey(tab.title(isAssemblyAI: settings.isAssemblyAIModel)))
                .fontWeight(selection == item ? .semibold : .regular)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(2)
                .frame(maxWidth: .infinity, alignment: .leading)
              shortcutHint(for: item)
                .layoutPriority(0)
            }
            .contentShape(Rectangle())
            .padding(.leading, 10)
          }
          .buttonStyle(.plain)
          .focusable(true)
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .background(
            selection == item
              ? RoundedRectangle(cornerRadius: 8)
                .fill(Color.brandAccentWarm.opacity(0.15))
              : nil
          )
          .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
          .listRowBackground(Color.clear)
          .speakTooltip(item.helpMessage)
          .accessibilityLabel(item.title(isAssemblyAI: settings.isAssemblyAIModel))
          .accessibilityHint(accessibilityHint(for: item))
        }
      }
    }
    .listStyle(.sidebar)
    .scrollContentBackground(.hidden)
  }

  @ViewBuilder
  private func shortcutHint(for item: SidebarItem) -> some View {
    let binding = shortcutManager.binding(for: item.shortcutAction)
    if settings.showSidebarShortcutHints && binding.isEnabled {
      Text(binding.displayString)
        .font(.caption2.monospaced())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.secondary.opacity(0.10)))
        .fixedSize()
        .layoutPriority(0)
        .accessibilityHidden(true)
    }
  }

  private func accessibilityHint(for item: SidebarItem) -> String {
    let binding = shortcutManager.binding(for: item.shortcutAction)
    guard settings.showSidebarShortcutHints && binding.isEnabled else {
      return item.helpMessage
    }
    return "\(item.helpMessage) Shortcut: \(binding.displayString)."
  }
}

private extension SettingsTab {
  var shortcutAction: ShortcutAction {
    switch self {
    case .general:
      return .openSettings
    case .transcription:
      return .openTranscriptionSettings
    case .postProcessing:
      return .openPostProcessingSettings
    case .voiceOutput:
      return .openVoiceOutputSettings
    case .pronunciation:
      return .openPronunciationSettings
    case .apiKeys:
      return .openAPIKeysSettings
    case .shortcuts:
      return .openKeyboardSettings
    case .permissions:
      return .openPermissionsSettings
    case .about:
      return .openAboutSettings
    }
  }
}

struct SideBarView_Previews: PreviewProvider {
  static var previews: some View {
    SideBarView(selection: .constant(.dashboard))
  }
}
// @Implement: This shows the items available in the sidebar. There is a dashboard, history,
// corrections hub, and settings.
