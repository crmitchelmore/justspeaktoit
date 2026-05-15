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
    .onReceive(environment.$sidebarNavigationTarget) { item in
      guard let item else { return }
      selection = item
    }
    .task {
      environment.installStatusBarIfNeeded {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
      }
    }
    .alert(
      environment.main.missingLiveAPIKeyAlert?.title ?? "API key required",
      isPresented: Binding(
        get: { environment.main.missingLiveAPIKeyAlert != nil },
        set: { if !$0 { environment.main.missingLiveAPIKeyAlert = nil } }
      ),
      presenting: environment.main.missingLiveAPIKeyAlert
    ) { alert in
      Button("Add API Key") {
        let target = "transcription-\(alert.provider.id)"
        environment.apiKeysScrollTarget = target
        selection = .settings(.apiKeys)
        environment.main.missingLiveAPIKeyAlert = nil
      }
      Button("Cancel", role: .cancel) {
        environment.main.missingLiveAPIKeyAlert = nil
      }
    } message: { alert in
      Text(alert.message)
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
    case .troubleshooting:
      TroubleshootingView(sidebarSelection: $selection)
    case .settings(let tab):
      SettingsView(tab: tab, sidebarSelection: $selection)
    }
  }

  @ToolbarContentBuilder
  private var toolbar: some ToolbarContent {
    ToolbarItem(placement: .primaryAction) {
      Button(action: environment.main.toggleRecordingFromUI) {
        switch environment.main.state {
        case .idle, .completed, .failed:
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
    case .idle, .completed, .failed:
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

// @Implement This is the main app container and handles top-level system events.
// It owns the sidebar selection and displays the selected content in the main window.
