import SpeakCore
import SpeakHotKeys
import SpeakSync
import AppKit
import SwiftUI

extension SettingsView {
  var permissionsSettings: some View {
    SpeakDensitySettingsSection(density: settings.visualDensity) {
      SettingsCard(title: "System permissions", systemImage: "lock.shield", tint: Color.red) {
        VStack(alignment: .leading, spacing: 12) {
          ForEach(PermissionType.availablePermissions(for: DistributionChannel.current)) { permission in
            let status = environment.permissions.status(for: permission)
            VStack(alignment: .leading, spacing: 8) {
              HStack(spacing: 12) {
                Label(permission.displayName, systemImage: permission.systemIconName)
                Spacer()
                Text(statusLabel(for: status))
                  .padding(.horizontal, 8)
                  .padding(.vertical, 4)
                  .background(statusColor(status).opacity(0.15), in: Capsule())
                  .foregroundStyle(statusColor(status))
                Button("Open Settings") {
                  openSettings(for: permission)
                }
                .buttonStyle(.bordered)
                .speakTooltip("Open the macOS privacy pane for \(permission.displayName).")
                Button("Request") {
                  Task { await environment.permissions.request(permission) }
                }
                .buttonStyle(.bordered)
                .speakTooltip("Ask macOS to prompt again for \(permission.displayName) access.")
              }

              if shouldShowManualSetupHelp(for: permission, status: status),
                 let steps = permission.manualSetupSteps {
                permissionManualSetupNote(for: permission, steps: steps)
              }

              if let issue = environment.permissions.requestIssue(for: permission) {
                channelAvailabilityNote(issue.guidance(for: permission))
              }
            }
          }

          Button("Refresh Statuses") {
            environment.permissions.refreshAll()
          }
          .buttonStyle(.borderedProminent)
          .speakTooltip("Re-check what the system currently allows without leaving Speak.")
        }
      }
      .speakTooltip("Review and refresh the macOS permissions Speak depends on.")
    }
    .task {
      while !Task.isCancelled {
        environment.permissions.refreshAll()
        try? await Task.sleep(for: .seconds(1))
      }
    }
  }

  func statusLabel(for status: PermissionStatus) -> String {
    switch status {
    case .granted: return "Granted"
    case .denied: return "Denied"
    case .restricted: return "Restricted"
    case .notDetermined: return "Pending"
    }
  }

  private func openSettings(for permission: PermissionType) {
    NSWorkspace.shared.open(permission.settingsURL)
  }

  private func shouldShowManualSetupHelp(for permission: PermissionType, status: PermissionStatus) -> Bool {
    guard permission.manualSetupSteps != nil else { return false }
    if status == .denied { return true }
    // Only Accessibility lacks an automatic prompt in sandboxed (App Store) builds.
    // Input Monitoring still prompts via CGRequestListenEventAccess even when sandboxed,
    // so it only needs manual guidance once the user has actively denied it (handled above).
    return permission == .accessibility
      && !DistributionChannel.current.supportsAutomaticAccessibilityPrompt
  }

  private func permissionManualSetupNote(for permission: PermissionType, steps: [String]) -> some View {
    let cannotAutoPrompt = permission == .accessibility
      && !DistributionChannel.current.supportsAutomaticAccessibilityPrompt
    let intro = if cannotAutoPrompt {
      "This build cannot show the automatic prompt here. Add \(permission.displayName) manually:"
    } else {
      "Add \(permission.displayName) manually:"
    }
    return channelAvailabilityNote("\(intro) \(steps.joined(separator: " "))")
  }

  func volumeLabel(for volume: Float) -> String {
    let percent = Int(volume * 100)
    return "\(percent)%"
  }

  private func statusColor(_ status: PermissionStatus) -> Color {
    switch status {
    case .granted: return .green
    case .denied: return .red
    case .restricted: return .orange
    case .notDetermined: return .yellow
    }
  }
}
