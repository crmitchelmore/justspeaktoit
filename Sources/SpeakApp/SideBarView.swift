import SpeakCore
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

  /// Rows in the "Speak" section, in display order.
  static let speakItems: [SidebarItem] = [
    .dashboard,
    .history,
    .voiceOutput,
    .corrections,
    .troubleshooting
  ]

  /// Rows in the "Settings" section, in display order.
  static var settingsItems: [SidebarItem] {
    SettingsTab.allCases.map(SidebarItem.settings)
  }

  /// Every sidebar row in keyboard-traversal order.
  ///
  /// The sidebar `List` owns selection, so the arrow keys walk exactly this
  /// order, crossing the section boundary between `.troubleshooting` and the
  /// first settings tab. Kept beside the row definitions so the traversal
  /// order stays testable without rendering the view.
  static var orderedItems: [SidebarItem] {
    speakItems + settingsItems
  }
}

extension Binding where Value == SidebarItem? {
  /// A sidebar-selection binding that refuses to go empty.
  ///
  /// `List(selection:)` clears the selection when the highlighted row is
  /// ⌘-clicked or when empty space below the rows is clicked. The detail pane
  /// then falls back to the dashboard while no row is highlighted, so the
  /// window looks like it has lost its place. Swallowing the `nil` keeps the
  /// row and the detail pane agreeing; every real row selection still lands.
  var clampedToLastSelection: Binding<SidebarItem?> {
    Binding(
      get: { wrappedValue },
      set: { newValue in
        guard let newValue else { return }
        wrappedValue = newValue
      }
    )
  }
}

struct SideBarView: View {
  @Binding var selection: SidebarItem?
  @EnvironmentObject private var settings: AppSettings
  @EnvironmentObject private var shortcutManager: ShortcutManager

  var body: some View {
    // `List` owns selection, so the arrow keys, type-select and the system
    // focus ring work without any hand-rolled focus scaffolding. Rows are
    // plain content tagged with their item rather than buttons, because a
    // button swallows the row's selection semantics.
    List(selection: $selection) {
      Section {
        ForEach(SidebarItem.speakItems) { item in
          sidebarRow(for: item)
        }
      } header: {
        sidebarSectionHeader("Speak")
      }

      Section {
        ForEach(SidebarItem.settingsItems) { item in
          sidebarRow(for: item, indented: true)
        }
      } header: {
        sidebarSectionHeader("Settings")
      }
    }
    .listStyle(.sidebar)
    .scrollContentBackground(.hidden)
  }

  private func sidebarRow(for item: SidebarItem, indented: Bool = false) -> some View {
    let isSelected = selection == item
    let title = item.title(isAssemblyAI: settings.isActiveAssemblyAILiveModel)

    return HStack(spacing: settings.visualDensity.inlineSpacing) {
      Image(systemName: item.systemImage)
        .foregroundStyle(item.color)
        .imageScale(settings.visualDensity.isCompact ? .small : .medium)
        .frame(width: settings.visualDensity.isCompact ? 16 : 20)
      sidebarTitle(title, isSelected: isSelected)
      ViewThatFits(in: .horizontal) {
        shortcutHint(for: item)
        EmptyView()
      }
    }
    .contentShape(Rectangle())
    .padding(.leading, indented && !settings.visualDensity.isCompact ? 10 : 0)
    .padding(.horizontal, settings.visualDensity.isCompact ? 4 : 12)
    .padding(.vertical, settings.visualDensity.isCompact ? 2 : 8)
    .tag(item)
    .listRowInsets(sidebarInsets)
    .listRowBackground(selectionBackground(for: item))
    .speakTooltip(item.helpMessage)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(title)
    .accessibilityHint(accessibilityHint(for: item))
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    .accessibilityValue(isSelected ? "Selected" : "")
    .accessibilityIdentifier(item.accessibilityID)
  }

  /// The brand selection tint, moved onto the row background so it survives
  /// `List` selection instead of being painted inside a button label.
  ///
  /// Padded by `sidebarInsets` because a row background spans the whole row
  /// while `listRowInsets` only insets the row's content, and the tint should
  /// keep hugging the content the way it did before.
  @ViewBuilder
  private func selectionBackground(for item: SidebarItem) -> some View {
    if selection == item {
      RoundedRectangle(cornerRadius: 8)
        .fill(item.color.opacity(0.15))
        .padding(sidebarInsets)
    } else {
      Color.clear
    }
  }

  private func sidebarTitle(_ title: String, isSelected: Bool) -> some View {
    let font: Font = settings.visualDensity.isCompact ? .caption : .body

    return ZStack(alignment: .leading) {
      // Always reserve the selected label's width so changing font weight cannot
      // cause a long title to wrap and change the sidebar row's height.
      Text(title)
        .font(font)
        .fontWeight(.semibold)
        .hidden()

      Text(title)
        .font(font)
        .fontWeight(isSelected ? .semibold : .regular)
        .foregroundStyle(.primary)
    }
    .lineLimit(1)
    .truncationMode(.tail)
    .multilineTextAlignment(.leading)
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
