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
      return LocalizedStringKey(tab.title)
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
}

struct SideBarView: View {
  @Binding var selection: SidebarItem?
  @EnvironmentObject private var settings: AppSettings

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
              Text(item.label)
                .fontWeight(selection == item ? .semibold : .regular)
                .foregroundStyle(.primary)
              Spacer()
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
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
              Spacer()
            }
            .contentShape(Rectangle())
            .padding(.leading, 10)
          }
          .buttonStyle(.plain)
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
        }
      }
    }
    .listStyle(.sidebar)
    .scrollContentBackground(.hidden)
  }
}

struct SideBarView_Previews: PreviewProvider {
  static var previews: some View {
    SideBarView(selection: .constant(.dashboard))
  }
}
// @Implement: This shows the items available in the sidebar. There is a dashboard, history, corrections hub, and settings.
