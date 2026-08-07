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

  /// Stable identifier for UI tests and assistive technologies.
  var accessibilityID: String {
    switch self {
    case .dashboard:
      return "sidebarDashboard"
    case .history:
      return "sidebarHistory"
    case .voiceOutput:
      return "sidebarVoiceOutput"
    case .corrections:
      return "sidebarCorrections"
    case .troubleshooting:
      return "sidebarTroubleshooting"
    case .settings(let tab):
      return "sidebarSettings-\(tab.rawValue)"
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
      Section {
        ForEach([SidebarItem.dashboard, .history, .voiceOutput, .corrections, .troubleshooting]) { item in
          Button {
            selection = item
          } label: {
            HStack(spacing: settings.visualDensity.inlineSpacing) {
              Image(systemName: item.systemImage)
                .foregroundStyle(item.color)
                .imageScale(settings.visualDensity.isCompact ? .small : .medium)
                .frame(width: settings.visualDensity.isCompact ? 16 : 20)
              sidebarTitle(
                item.title(isAssemblyAI: settings.isActiveAssemblyAILiveModel),
                isSelected: selection == item
              )
              ViewThatFits(in: .horizontal) {
                shortcutHint(for: item)
                EmptyView()
              }
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .focusable(true)
          .focusEffectDisabled()
          .padding(.horizontal, settings.visualDensity.isCompact ? 4 : 12)
          .padding(.vertical, settings.visualDensity.isCompact ? 2 : 8)
          .background(
            selection == item
              ? RoundedRectangle(cornerRadius: 8)
                .fill(item.color.opacity(0.15))
              : nil
          )
          .listRowInsets(sidebarInsets)
          .listRowBackground(Color.clear)
          .speakTooltip(item.helpMessage)
          .accessibilityLabel(item.title(isAssemblyAI: settings.isActiveAssemblyAILiveModel))
          .accessibilityHint(accessibilityHint(for: item))
          .accessibilityAddTraits(selection == item ? [.isButton, .isSelected] : .isButton)
          .accessibilityValue(selection == item ? "Selected" : "")
          .accessibilityIdentifier(item.accessibilityID)
        }
      } header: {
        sidebarSectionHeader("Speak")
      }

      Section {
        ForEach(SettingsTab.allCases) { tab in
          let item = SidebarItem.settings(tab)
          Button {
            selection = item
          } label: {
            HStack(spacing: settings.visualDensity.inlineSpacing) {
              Image(systemName: tab.systemImage)
                .foregroundStyle(Color.brandAccentWarm)
                .imageScale(settings.visualDensity.isCompact ? .small : .medium)
                .frame(width: settings.visualDensity.isCompact ? 16 : 20)
              sidebarTitle(tab.title(isAssemblyAI: settings.isActiveAssemblyAILiveModel), isSelected: selection == item)
              ViewThatFits(in: .horizontal) {
                shortcutHint(for: item)
                EmptyView()
              }
            }
            .contentShape(Rectangle())
            .padding(.leading, settings.visualDensity.isCompact ? 0 : 10)
          }
          .buttonStyle(.plain)
          .focusable(true)
          .focusEffectDisabled()
          .padding(.horizontal, settings.visualDensity.isCompact ? 4 : 12)
          .padding(.vertical, settings.visualDensity.isCompact ? 2 : 8)
          .background(
            selection == item
              ? RoundedRectangle(cornerRadius: 8)
                .fill(Color.brandAccentWarm.opacity(0.15))
              : nil
          )
          .listRowInsets(sidebarInsets)
          .listRowBackground(Color.clear)
          .speakTooltip(item.helpMessage)
          .accessibilityLabel(item.title(isAssemblyAI: settings.isActiveAssemblyAILiveModel))
          .accessibilityHint(accessibilityHint(for: item))
          .accessibilityAddTraits(selection == item ? [.isButton, .isSelected] : .isButton)
          .accessibilityValue(selection == item ? "Selected" : "")
          .accessibilityIdentifier(item.accessibilityID)
        }
      } header: {
        sidebarSectionHeader("Settings")
      }
    }
    .listStyle(.sidebar)
    .scrollContentBackground(.hidden)
  }

  private func sidebarTitle(_ title: String, isSelected: Bool) -> some View {
    Text(title)
      .font(settings.visualDensity.isCompact ? .caption : .body)
      .fontWeight(isSelected ? .semibold : .regular)
      .foregroundStyle(.primary)
      .lineLimit(settings.visualDensity.isCompact ? 1 : nil)
      .multilineTextAlignment(.leading)
      .fixedSize(horizontal: false, vertical: true)
      .layoutPriority(3)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private func shortcutHint(for item: SidebarItem) -> some View {
    let binding = shortcutManager.binding(for: item.shortcutAction)
    if settings.showSidebarShortcutHints,
       binding.isEnabled {
      Text(binding.displayString)
        .font(
          settings.visualDensity.isCompact
            ? .system(size: 9, weight: .medium, design: .monospaced)
            : .caption2.monospaced()
        )
        .foregroundStyle(.secondary)
        .padding(.horizontal, settings.visualDensity.isCompact ? 0 : 6)
        .padding(.vertical, settings.visualDensity.isCompact ? 0 : 2)
        .background {
          if !settings.visualDensity.isCompact {
            Capsule().fill(Color.secondary.opacity(0.10))
          }
        }
        .minimumScaleFactor(0.8)
        .layoutPriority(settings.visualDensity.isCompact ? 4 : -1)
        .accessibilityHidden(true)
    }
  }

  private var sidebarInsets: EdgeInsets {
    let inset: CGFloat = settings.visualDensity.isCompact ? 2 : 8
    let verticalInset: CGFloat = settings.visualDensity.isCompact ? 1 : 2
    return EdgeInsets(
      top: verticalInset,
      leading: inset,
      bottom: verticalInset,
      trailing: inset
    )
  }

  @ViewBuilder
  private func sidebarSectionHeader(_ title: String) -> some View {
    if settings.visualDensity.isCompact {
      Text(title)
        .font(.caption2)
        .fontWeight(.semibold)
        .textCase(nil)
    } else {
      Text(title)
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
    case .profiles:
      return .openProfilesSettings
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
