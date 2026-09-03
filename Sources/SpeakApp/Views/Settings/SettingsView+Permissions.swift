import SpeakCore
import SpeakHotKeys
import SpeakSync
import AppKit
import SwiftUI

extension SettingsView {
  var permissionsSettings: some View {
    // The rows live in their own view that observes `PermissionsManager`
    // directly. `SettingsView` only observes `AppEnvironment`, so reading the
    // manager through it never invalidated this tab: statuses changed under the
    // hood (Refresh, the polling task, System Settings grants) but the pills
    // kept their old value until the tab was recreated (issue #860).
    PermissionsSettingsContent(permissions: environment.permissions, density: settings.visualDensity)
  }

  func statusLabel(for status: PermissionStatus) -> String {
    PermissionsSettingsContent.statusLabel(for: status)
  }

  func volumeLabel(for volume: Float) -> String {
    let percent = Int(volume * 100)
    return "\(percent)%"
  }
}

struct PermissionsSettingsContent: View {
  @ObservedObject var permissions: PermissionsManager
  let density: AppVisualDensity

  var body: some View {
    SpeakDensitySettingsSection(density: density) {
      SettingsCard(title: "System permissions", systemImage: "lock.shield", tint: Color.red) {
        VStack(alignment: .leading, spacing: 12) {
          ForEach(PermissionType.availablePermissions(for: DistributionChannel.current)) { permission in
            let status = permissions.status(for: permission)
            VStack(alignment: .leading, spacing: 8) {
              HStack(spacing: 12) {
                Label(permission.displayName, systemImage: permission.systemIconName)
                Spacer()
                Text(Self.statusLabel(for: status))
                  .padding(.horizontal, 8)
                  .padding(.vertical, 4)
                  .background(Self.statusColor(status).opacity(0.15), in: Capsule())
                  .foregroundStyle(Self.statusColor(status))
                  .accessibilityIdentifier("permissions.status.\(String(describing: permission))")
                Button("Open Settings") {
                  NSWorkspace.shared.open(permission.settingsURL)
                }
                .buttonStyle(.bordered)
                .speakTooltip("Open the macOS privacy pane for \(permission.displayName).")
                Button("Request") {
                  Task { await permissions.request(permission) }
                }
                .buttonStyle(.bordered)
                .speakTooltip("Ask macOS to prompt again for \(permission.displayName) access.")
              }

              if Self.shouldShowManualSetupHelp(for: permission, status: status),
                 let steps = permission.manualSetupSteps {
                Self.manualSetupNote(for: permission, steps: steps)
              }

              if let issue = permissions.requestIssue(for: permission) {
                Self.note(issue.guidance(for: permission))
              }
            }
          }

          Button("Refresh Statuses") {
            permissions.refreshAll()
          }
          .buttonStyle(.borderedProminent)
          .speakTooltip("Re-check what the system currently allows without leaving Speak.")
        }
      }
      .speakTooltip("Review and refresh the macOS permissions Speak depends on.")
    }
    .task {
      while !Task.isCancelled {
        permissions.refreshAll()
        try? await Task.sleep(for: .seconds(1))
      }
    }
  }

  static func statusLabel(for status: PermissionStatus) -> String {
    switch status {
    case .granted: return "Granted"
    case .denied: return "Denied"
    case .restricted: return "Restricted"
    case .notDetermined: return "Pending"
    }
  }

  private static func statusColor(_ status: PermissionStatus) -> Color {
    switch status {
    case .granted: return .green
    case .denied: return .red
    case .restricted: return .orange
    case .notDetermined: return .yellow
    }
  }

  private static func shouldShowManualSetupHelp(for permission: PermissionType, status: PermissionStatus) -> Bool {
    guard permission.manualSetupSteps != nil else { return false }
    if status == .denied { return true }
    // Only Accessibility lacks an automatic prompt in sandboxed (App Store) builds.
    // Input Monitoring still prompts via CGRequestListenEventAccess even when sandboxed,
    // so it only needs manual guidance once the user has actively denied it (handled above).
    return permission == .accessibility
      && !DistributionChannel.current.supportsAutomaticAccessibilityPrompt
  }

  private static func manualSetupNote(for permission: PermissionType, steps: [String]) -> some View {
    let cannotAutoPrompt = permission == .accessibility
      && !DistributionChannel.current.supportsAutomaticAccessibilityPrompt
    let intro = if cannotAutoPrompt {
      "This build cannot show the automatic prompt here. Add \(permission.displayName) manually:"
    } else {
      "Add \(permission.displayName) manually:"
    }
    return note("\(intro) \(steps.joined(separator: " "))")
  }

  private static func note(_ text: String) -> some View {
    Label(text, systemImage: "info.circle")
      .font(.caption)
      .foregroundStyle(.secondary)
  }
}
