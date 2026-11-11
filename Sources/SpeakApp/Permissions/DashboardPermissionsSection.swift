import SpeakCore
import SwiftUI

/// Observe the permission authority directly, including grants made while Settings is frontmost.
struct DashboardPermissionsSection: View {
  @ObservedObject var permissions: PermissionsManager
  @Environment(\.appVisualDensity) private var density
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @State private var requestingPermission: PermissionType?

  var body: some View {
    DashboardCard(title: "Permissions", systemImage: "lock.shield", tint: Color.brandAccentWarm) {
      LazyVGrid(
        columns: Array(
          repeating: GridItem(.flexible(), spacing: density.groupSpacing),
          count: 2
        ),
        spacing: density.groupSpacing
      ) {
        ForEach(PermissionType.availablePermissions(for: DistributionChannel.current)) { permission in
          permissionCard(for: permission)
        }
      }
    }
    .task {
      while !Task.isCancelled {
        permissions.refreshAll()
        do { try await Task.sleep(for: .seconds(1)) } catch { return }
      }
    }
    .speakTooltip("Review and grant the permissions Speak needs so recordings and shortcuts work reliably.")
  }

  private func permissionCard(for permission: PermissionType) -> some View {
    let status = permissions.status(for: permission)
    return Group {
      if density.prefersInlineLayout(dynamicTypeSize: dynamicTypeSize) {
        compactPermissionCard(for: permission, status: status)
      } else {
        regularPermissionCard(for: permission, status: status)
      }
    }
    .speakTooltip(permission.guidanceText)
  }

  private func compactPermissionCard(
    for permission: PermissionType,
    status: PermissionStatus
  ) -> some View {
    HStack(spacing: density.inlineSpacing) {
      Image(systemName: permission.systemIconName)
        .frame(width: 16)
      VStack(alignment: .leading, spacing: 0) {
        Text(permission.displayName)
          .font(.caption.weight(.semibold))
          .lineLimit(1)
        Text(statusDescription(status))
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 2)
      Circle()
        .fill(statusColor(status))
        .frame(width: 7, height: 7)
      compactPermissionAction(for: permission, status: status)
    }
    .padding(6)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(.ultraThinMaterial)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(statusColor(status).opacity(0.35), lineWidth: 1)
    )
  }

  @ViewBuilder
  private func compactPermissionAction(
    for permission: PermissionType,
    status: PermissionStatus
  ) -> some View {
    if permissions.requestIssue(for: permission) != nil {
      Button {
        permissions.openSettings(for: permission)
      } label: {
        Label("Open Settings", systemImage: "gear")
          .labelStyle(.iconOnly)
      }
      .buttonStyle(.borderless)
    } else {
      Button {
        requestingPermission = permission
        Task { await request(permission) }
      } label: {
        Label(
          status.isGranted ? "Check" : "Request",
          systemImage: status.isGranted ? "arrow.clockwise" : "plus.circle"
        )
        .labelStyle(.iconOnly)
      }
      .buttonStyle(.borderless)
    }
  }

  private func regularPermissionCard(
    for permission: PermissionType,
    status: PermissionStatus
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Image(systemName: permission.systemIconName)
          .imageScale(.large)
        Text(permission.displayName)
          .font(.headline)
        Spacer()
        Circle()
          .fill(statusColor(status))
          .frame(width: 12, height: 12)
      }
      Text(statusDescription(status))
        .font(.subheadline)
        .foregroundStyle(.secondary)

      if let issue = permissions.requestIssue(for: permission) {
        Text(issue.guidance(for: permission))
          .font(.caption)
          .foregroundStyle(.orange)
        Button("Open Settings") {
          permissions.openSettings(for: permission)
        }
          .buttonStyle(.bordered)
          .controlSize(.small)
      } else {
        Button(status.isGranted ? "Check" : "Request") {
          requestingPermission = permission
          Task { await request(permission) }
        }
        .controlSize(.small)
        .speakTooltip(permission.guidanceText)
      }
    }
    .padding()
    .background(
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .fill(.ultraThinMaterial)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .stroke(statusColor(status).opacity(0.4), lineWidth: 1)
    )
  }

  private func request(_ permission: PermissionType) async {
    _ = await permissions.requestWithGuidance(permission)
    await MainActor.run {
      requestingPermission = nil
    }
  }

  private func statusColor(_ status: PermissionStatus) -> Color {
    switch status {
    case .granted:
      return .green
    case .denied:
      return .red
    case .restricted:
      return .orange
    case .notDetermined:
      return .yellow
    }
  }

  private func statusDescription(_ status: PermissionStatus) -> String {
    switch status {
    case .granted:
      return "Granted"
    case .denied:
      return "Denied"
    case .restricted:
      return "Restricted"
    case .notDetermined:
      return "Not requested"
    }
  }

}
