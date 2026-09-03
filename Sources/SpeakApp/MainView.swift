import AppKit
import SpeakCore
import SwiftUI

struct MainView: View {
  @EnvironmentObject private var environment: AppEnvironment
  @EnvironmentObject private var history: HistoryManager
  @EnvironmentObject private var personalLexicon: PersonalLexiconService
  @EnvironmentObject private var settings: AppSettings
  @State private var selection: SidebarItem? = .dashboard

  var body: some View {
    NavigationSplitView {
      SideBarView(selection: $selection.clampedToLastSelection)
        .navigationSplitViewColumnWidth(
          min: settings.visualDensity.isCompact ? 170 : 220,
          ideal: settings.visualDensity.isCompact ? 188 : 240,
          max: settings.visualDensity.isCompact ? 240 : 320
        )
    } detail: {
      detailView
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(settings.visualDensity.isCompact ? 0 : 16)
        .controlSize(settings.visualDensity.isCompact ? .small : .regular)
        .background(Color(nsColor: .windowBackgroundColor))
    }
    .frame(minWidth: 960, minHeight: 640)
    .environment(\.appVisualDensity, settings.visualDensity)
    .toolbar { toolbar }
    .onReceive(environment.$sidebarNavigationTarget) { item in
      guard let item else { return }
      selection = item
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
      if let url = alert.provider.apiKeyURL {
        Button("Get API Key") {
          NSWorkspace.shared.open(url)
          environment.main.missingLiveAPIKeyAlert = nil
        }
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
    // The sidebar binding is clamped (`clampedToLastSelection`), so `selection`
    // never actually goes nil once set; the fallback only covers a nil initial
    // value.
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
        toolbarRecordLabel
      }
      // No shortcut here: Start/Stop Recording has one canonical binding, owned
      // by ShortcutManager and installed on exactly one menu item — the Speak
      // menu's, built by MenuBarManager.
      .speakTooltip("Start or stop a recording from anywhere in Speak. We'll let you know when we're listening.")
      .accessibilityLabel(recordButtonAccessibility.label)
      .accessibilityHint(recordButtonAccessibility.hint)
      .accessibilityAddTraits(recordButtonAccessibility.traits)
      .accessibilityIdentifier("toolbarRecordToggleButton")
      .disabled(isRecordButtonDisabled)
    }
    if !settings.visualDensity.isCompact {
      ToolbarItem(placement: .status) {
        VStack(alignment: .trailing, spacing: 2) {
          Text(environment.settings.effectiveTranscriptionModeDisplayName)
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
        .accessibilityLabel("Current mode: \(environment.settings.effectiveTranscriptionModeDisplayName)")
      }
    }
  }

  @ViewBuilder
  private var toolbarRecordLabel: some View {
    switch environment.main.state {
    case .idle, .completed, .failed:
      if settings.visualDensity.isCompact {
        Label("Record", systemImage: "mic")
          .labelStyle(.iconOnly)
      } else {
        Label("Record", systemImage: "mic")
      }
    case .recording:
      if settings.visualDensity.isCompact {
        Label("Stop", systemImage: "stop.fill")
          .labelStyle(.iconOnly)
          .foregroundStyle(.red)
      } else {
        Label("Stop", systemImage: "stop.fill")
          .foregroundStyle(.red)
      }
    case .processing, .delivering:
      ProgressView()
    }
  }

  private var recordButtonAccessibility: RecordingControlAccessibility {
    RecordingControlAccessibility(state: environment.main.state)
  }

  private var isRecordButtonDisabled: Bool {
    switch environment.main.state {
    case .processing, .delivering:
      return true
    case .idle, .recording, .completed, .failed:
      return false
    }
  }
}

// @Implement This is the main app container and handles top-level system events.
// It owns the sidebar selection and displays the selected content in the main window.
