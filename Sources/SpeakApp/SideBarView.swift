import SwiftUI

enum SidebarItem: Hashable, Identifiable {
  case dashboard
  case history
  case settings

  var id: Self { self }

  var label: LocalizedStringKey {
    switch self {
    case .dashboard:
      return "Dashboard"
    case .history:
      return "History"
    case .settings:
      return "Settings"
    }
  }

  var systemImage: String {
    switch self {
    case .dashboard:
      return "waveform"
    case .history:
      return "clock"
    case .settings:
      return "gearshape"
    }
  }
}

struct SideBarView: View {
  @Binding var selection: SidebarItem?

  var body: some View {
    List(selection: $selection) {
      Section("Speak") {
        ForEach([SidebarItem.dashboard, .history, .settings]) { item in
          NavigationLink(value: item) {
            Label(item.label, systemImage: item.systemImage)
          }
        }
      }
    }
    .listStyle(.sidebar)
  }
}

struct SideBarView_Previews: PreviewProvider {
  static var previews: some View {
    SideBarView(selection: .constant(.dashboard))
  }
}
// @Implement: This shows the items available in the sidebar. There is a dashboard, settings, and History.
