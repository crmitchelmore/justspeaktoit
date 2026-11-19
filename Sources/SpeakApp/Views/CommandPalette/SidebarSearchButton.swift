import SwiftUI

/// Opens the "Search for anything" palette from the top of the sidebar. Drawn
/// as a search field so it reads as one, but it is a button: typing happens in
/// the palette.
struct SidebarSearchButton: View {
  @EnvironmentObject private var environment: AppEnvironment
  @EnvironmentObject private var settings: AppSettings
  @EnvironmentObject private var shortcutManager: ShortcutManager

  var body: some View {
    let binding = shortcutManager.binding(for: .openCommandPalette)
    let shortcut = binding.isEnabled ? binding.displayString : nil
    return Button {
      environment.isSettingsSearchPresented = true
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        Text("Search for anything")
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .frame(maxWidth: .infinity, alignment: .leading)
        if let shortcut {
          Text(shortcut)
            .font(.caption2.monospaced())
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
        }
      }
      .font(settings.visualDensity.isCompact ? .caption : .body)
      .padding(.horizontal, 8)
      .padding(.vertical, settings.visualDensity.isCompact ? 3 : 5)
      .background(
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .fill(Color.primary.opacity(0.06))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .padding(.horizontal, settings.visualDensity.isCompact ? 6 : 10)
    .padding(.top, settings.visualDensity.isCompact ? 4 : 8)
    .padding(.bottom, 4)
    .speakTooltip("Search actions, settings, API keys and shortcuts.")
    .accessibilityLabel("Search for anything")
    .accessibilityHint(shortcut.map { "Run an action or find a setting. Shortcut: \($0)." }
      ?? "Run an action or find a setting.")
    .accessibilityIdentifier("sidebarSearchButton")
  }
}
