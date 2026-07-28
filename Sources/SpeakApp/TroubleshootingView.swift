import SpeakCore
import SwiftUI

struct TroubleshootingView: View {
  @EnvironmentObject private var environment: AppEnvironment
  @Environment(\.appVisualDensity) private var density
  @StateObject private var analyser = TroubleshootingAnalyser()
  @Binding var sidebarSelection: SidebarItem?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: density.isCompact ? density.sectionSpacing : 24) {
        header
        if analyser.items.isEmpty {
          allClearBanner
        } else {
          itemsList
        }
      }
      .padding(density.pagePadding)
    }
    .onAppear { runAnalysis() }
    .onChange(of: environment.settings.restoreClipboardAfterPaste) { runAnalysis() }
    .onChange(of: environment.settings.postProcessingEnabled) { runAnalysis() }
    .onChange(of: environment.permissions.statuses) { runAnalysis() }
  }

  private func runAnalysis() {
    Task {
      await analyser.analyse(
        settings: environment.settings,
        permissions: environment.permissions,
        secureStorage: environment.secureStorage
      )
    }
  }

  // MARK: - Header

  private var header: some View {
    VStack(alignment: .leading, spacing: density.isCompact ? 1 : 8) {
      Label("Troubleshooting", systemImage: "stethoscope")
        .font(density.isCompact ? .subheadline.bold() : .title.bold())
      if !density.isCompact {
        Text("Common issues and quick fixes to get you up and running.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
    }
  }

  // MARK: - All Clear

  private var allClearBanner: some View {
    HStack(spacing: density.isCompact ? density.inlineSpacing : 12) {
      Image(systemName: "checkmark.seal.fill")
        .font(density.isCompact ? .caption : .title2)
        .foregroundStyle(.green)
      VStack(alignment: .leading, spacing: density.isCompact ? 0 : 2) {
        Text("Everything looks good")
          .font(density.isCompact ? .caption.weight(.semibold) : .headline)
        if !density.isCompact {
          Text("No issues detected with your current configuration.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
      }
      Spacer()
    }
    .padding(density.isCompact ? density.cardPadding : 16)
    .background(
      RoundedRectangle(cornerRadius: density.isCompact ? 8 : 12)
        .fill(.green.opacity(0.08))
    )
  }

  // MARK: - Items

  private var itemsList: some View {
    VStack(alignment: .leading, spacing: density.isCompact ? density.sectionSpacing : 12) {
      ForEach(analyser.items) { item in
        TroubleshootingItemRow(item: item) { tab in
          sidebarSelection = .settings(tab)
        }
      }
    }
  }
}

// MARK: - Item Row

private struct TroubleshootingItemRow: View {
  @Environment(\.appVisualDensity) private var density
  let item: TroubleshootingItem
  let navigateToTab: (SettingsTab) -> Void

  var body: some View {
    HStack(alignment: .top, spacing: density.isCompact ? density.inlineSpacing : 14) {
      statusIcon
      VStack(alignment: .leading, spacing: density.isCompact ? 2 : 6) {
        Text(item.title)
          .font(density.isCompact ? .caption.weight(.semibold) : .headline)
        Text(item.detail)
          .font(density.isCompact ? .caption2 : .subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(density.isCompact ? 1 : nil)
          .fixedSize(horizontal: false, vertical: !density.isCompact)
        actionButtons
      }
      Spacer()
    }
    .padding(density.isCompact ? density.cardPadding : 16)
    .background(
      RoundedRectangle(cornerRadius: density.isCompact ? 8 : 12)
        .fill(backgroundColour.opacity(0.08))
    )
    .overlay(
      RoundedRectangle(cornerRadius: density.isCompact ? 8 : 12)
        .strokeBorder(backgroundColour.opacity(0.2), lineWidth: 1)
    )
  }

  private var statusIcon: some View {
    Image(systemName: statusSystemImage)
      .font(density.isCompact ? .caption : .title2)
      .foregroundStyle(backgroundColour)
      .frame(width: density.isCompact ? 14 : 28)
  }

  private var statusSystemImage: String {
    switch item.status {
    case .issue: return "exclamationmark.triangle.fill"
    case .warning: return "exclamationmark.circle.fill"
    case .info: return "info.circle.fill"
    case .ok: return "checkmark.circle.fill"
    }
  }

  private var backgroundColour: Color {
    switch item.status {
    case .issue: return .red
    case .warning: return .orange
    case .info: return .blue
    case .ok: return .green
    }
  }

  @ViewBuilder
  private var actionButtons: some View {
    let actions = item.actions
    if !actions.isEmpty {
      HStack(spacing: 8) {
        ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
          switch action {
          case .autoFix(let fix):
            Button {
              fix()
            } label: {
              Label("Fix Now", systemImage: "wrench.and.screwdriver")
                .font(.caption.bold())
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
          case .navigate(let tab):
            Button {
              navigateToTab(tab)
            } label: {
              Label("Open \(tab.title)", systemImage: "arrow.right.circle")
                .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
          }
        }
      }
      .padding(.top, 4)
    }
  }
}
