import SwiftUI

struct MainView: View {
  @EnvironmentObject private var environment: AppEnvironment
  @EnvironmentObject private var history: HistoryManager
  @EnvironmentObject private var personalLexicon: PersonalLexiconService
  @State private var selection: SidebarItem? = .dashboard

  var body: some View {
    NavigationSplitView {
      SideBarView(selection: $selection)
        .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 320)
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
  }

  @ViewBuilder
  private var detailView: some View {
    switch selection ?? .dashboard {
    case .dashboard:
      DashboardView()
    case .history:
      HistoryView()
    case .voiceOutput:
      VoiceOutputView()
    case .corrections:
      PersonalCorrectionsView()
        .environmentObject(personalLexicon)
        .environmentObject(environment.autoCorrectionTracker)
        .environmentObject(environment.settings)
    case .settings(let tab):
      SettingsView(tab: tab)
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
      .speakTooltip("Start or stop a recording from anywhere in Speak. We'll let you know when we're listening.")
      .accessibilityLabel(accessibilityLabelForRecordButton)
    }
    ToolbarItem(placement: .status) {
      VStack(alignment: .trailing, spacing: 2) {
        Text(environment.settings.transcriptionMode.displayName)
          .font(.caption)
          .foregroundStyle(.secondary)
        if let item = history.items.first {
          Text("Last: \(item.createdAt.formatted())")
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .background(
        Capsule()
          .fill(.ultraThinMaterial)
      )
      .overlay(
        Capsule()
          .strokeBorder(.secondary.opacity(0.3), lineWidth: 0.5)
      )
      .accessibilityLabel("Current mode: \(environment.settings.transcriptionMode.displayName)")
    }
  }

  
  private var accessibilityLabelForRecordButton: String {
    switch environment.main.state {
    case .idle, .completed(_), .failed(_):
      return "Start recording"
    case .recording:
      return "Stop recording"
    case .processing:
      return "Processing recording"
    case .delivering:
      return "Delivering transcription"
    }
  }
}

// @Implement This is the main app container and handles all top-level system events. It has a sidebar on the left And then when items are selected, they're shown on the right in the main window. If it's the right place, this is where the status bar item and view should also be initialised.
