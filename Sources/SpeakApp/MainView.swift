import SwiftUI

struct MainView: View {
  @EnvironmentObject private var environment: AppEnvironment
  @State private var selection: SidebarItem? = .dashboard
  @State private var presentError: Bool = false
  @State private var latestErrorMessage: String = ""

  var body: some View {
    NavigationSplitView {
      SideBarView(selection: $selection)
    } detail: {
      detailView
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
    }
    .frame(minWidth: 960, minHeight: 640)
    .toolbar { toolbar }
    .task {
      environment.installStatusBarIfNeeded {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
      }
    }
    .onReceive(environment.main.$lastErrorMessage) { message in
      guard let message else { return }
      latestErrorMessage = message
      presentError = true
    }
    .alert(
      "Something went wrong", isPresented: $presentError,
      actions: {
        Button("Dismiss", role: .cancel) { presentError = false }
      },
      message: {
        Text(latestErrorMessage)
      })
  }

  @ViewBuilder
  private var detailView: some View {
    switch selection ?? .dashboard {
    case .dashboard:
      DashboardView()
    case .history:
      HistoryView()
    case .settings:
      SettingsView()
    }
  }

  @ToolbarContentBuilder
  private var toolbar: some ToolbarContent {
    ToolbarItem(placement: .primaryAction) {
      Button(action: environment.main.toggleRecordingFromUI) {
        switch environment.main.state {
        case .idle, .completed(_), .failed(_):
          Label("Record", systemImage: "mic")
        case .recording:
          Label("Stop", systemImage: "stop.fill")
            .foregroundStyle(.red)
        case .processing:
          ProgressView()
        case .delivering:
          ProgressView()
        }
      }
      .keyboardShortcut(.space, modifiers: [.command, .shift])
    }
    ToolbarItem(placement: .status) {
      VStack(alignment: .trailing, spacing: 2) {
        Text(environment.settings.transcriptionMode.displayName)
          .font(.caption)
          .foregroundStyle(.secondary)
        if let item = environment.history.items.first {
          Text("Last: \(item.createdAt.formatted())")
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
      }
    }
  }
}

// @Implement This is the main app container and handles all top-level system events. It has a sidebar on the left And then when items are selected, they're shown on the right in the main window. If it's the right place, this is where the status bar item and view should also be initialised.
