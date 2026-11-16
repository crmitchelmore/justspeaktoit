import SpeakCore
import SwiftUI

/// "Search for anything" (⌘K, or ⌘F): typeahead over app actions, the shared
/// settings catalogue and one entry per API-key card. Choosing an action runs it;
/// choosing a setting navigates to and highlights it.
struct SettingsSearchPalette: View {
  let onSelect: (CommandPaletteSearch.Item) -> Void

  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var shortcutManager: ShortcutManager
  @AppStorage("settingsSearch.recentEntryIDs") private var storedRecents = ""
  @State private var query = ""
  @State private var selectedIndex = 0
  @State private var search = CommandPaletteSearch(
    commands: CommandPaletteCommand.all(), settings: MacSettingsSearch.catalogEntries
  )
  @FocusState private var isFieldFocused: Bool

  private typealias Row = CommandPaletteSearch.Row

  var body: some View {
    let rows = visibleRows
    VStack(spacing: 0) {
      searchField(rows: rows)
      completionsBar
      Divider()
      results(rows)
    }
    .frame(width: 620, height: 480)
    .onAppear { isFieldFocused = true }
    .onChange(of: query) { _, _ in selectedIndex = 0 }
    .task {
      let providers = await TranscriptionProviderRegistry.shared.allProviders()
      search = CommandPaletteSearch(
        commands: CommandPaletteCommand.all(),
        settings: MacSettingsSearch.catalogEntries
          + MacSettingsSearch.apiKeyEntries(transcriptionProviders: providers)
      )
    }
  }

  private func searchField(rows: [Row]) -> some View {
    HStack(spacing: 10) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      TextField("Search for anything", text: $query)
        .textFieldStyle(.plain)
        .font(.title3)
        .focused($isFieldFocused)
        .accessibilityLabel("Search for anything")
        .accessibilityIdentifier("settingsSearchField")
        .onSubmit { choose(rows.indices.contains(selectedIndex) ? rows[selectedIndex] : rows.first) }
        .onKeyPress(.downArrow) {
          selectedIndex = min(selectedIndex + 1, max(rows.count - 1, 0))
          return .handled
        }
        .onKeyPress(.upArrow) {
          selectedIndex = max(selectedIndex - 1, 0)
          return .handled
        }
        .onKeyPress(.tab) {
          guard let completion = completions.first else { return .ignored }
          query = completion
          return .handled
        }
      Button("Close") { dismiss() }
        .keyboardShortcut(.cancelAction)
        .accessibilityIdentifier("settingsSearchCloseButton")
    }
    .padding(14)
  }

  private var completions: [String] {
    search.completions(for: query, limit: 5)
  }

  @ViewBuilder
  private var completionsBar: some View {
    let completions = completions
    if !completions.isEmpty {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 6) {
          Text("Suggestions")
            .font(.caption)
            .foregroundStyle(.secondary)
          ForEach(Array(completions.enumerated()), id: \.element) { position, completion in
            Button(completion) { query = completion }
              .buttonStyle(.bordered)
              .controlSize(.small)
              .accessibilityHint(position == 0 ? "Press Tab to complete" : "Completes the search")
              .accessibilityIdentifier("settingsSearchCompletion.\(position)")
          }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
      }
    }
  }

  @ViewBuilder
  private func results(_ rows: [Row]) -> some View {
    if rows.isEmpty {
      ContentUnavailableView.search(text: query)
        .frame(maxHeight: .infinity)
    } else {
      ScrollViewReader { proxy in
        List {
          ForEach(Array(rows.enumerated()), id: \.element.id) { position, row in
            if position == 0 || rows[position - 1].group != row.group {
              Text(row.group)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            }
            resultRow(row, isSelected: position == selectedIndex)
              .id(row.id)
          }
        }
        .listStyle(.plain)
        .accessibilityLabel(query.isEmpty ? "Actions and suggested settings" : "\(rows.count) results found")
        .onChange(of: selectedIndex) { _, newValue in
          guard rows.indices.contains(newValue) else { return }
          proxy.scrollTo(rows[newValue].id)
        }
      }
    }
  }

  @ViewBuilder
  private func resultRow(_ row: Row, isSelected: Bool) -> some View {
    switch row.item {
    case .command(let command):
      commandRow(command, row: row, isSelected: isSelected)
    case .setting(let entry):
      settingRow(entry, row: row, isSelected: isSelected)
    case .history:
      // The Mac palette passes no History to the shared search.
      EmptyView()
    }
  }

  private func commandRow(_ command: CommandPaletteCommand, row: Row, isSelected: Bool) -> some View {
    let binding = command.shortcutAction.map { shortcutManager.binding(for: $0) }
    let shortcut = binding.flatMap { $0.isEnabled ? $0.displayString : nil }
    return rowButton(row, isSelected: isSelected) {
      rowContent(
        systemImage: command.systemImage, title: command.title, caption: nil,
        detail: command.summary, trailing: shortcut
      )
    }
    .accessibilityLabel(command.title)
    .accessibilityHint(shortcut.map { "\(command.summary) Shortcut: \($0)." } ?? command.summary)
    .accessibilityIdentifier("commandPaletteResult.\(command.id)")
  }

  private func settingRow(_ entry: SettingsSearchEntry, row: Row, isSelected: Bool) -> some View {
    let detail = row.matchedKeyword.map { "Matches “\($0)” · \(entry.summary)" } ?? entry.summary
    return rowButton(row, isSelected: isSelected) {
      rowContent(
        systemImage: entry.systemImage, title: entry.title,
        caption: entry.isSectionRoot ? nil : entry.section.title, detail: detail, trailing: nil
      )
    }
    .accessibilityLabel(entry.isSectionRoot ? "\(entry.title) settings" : "\(entry.title), \(entry.section.title)")
    .accessibilityHint(detail)
    .accessibilityIdentifier(entry.resultAccessibilityIdentifier)
  }

  private func rowButton<Label: View>(
    _ row: Row, isSelected: Bool, @ViewBuilder label: () -> Label
  ) -> some View {
    Button {
      choose(row)
    } label: {
      label()
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .background(
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(isSelected ? Color.accentColor.opacity(0.18) : .clear)
        )
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .ignore)
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
  }

  private func rowContent(
    systemImage: String, title: String, caption: String?, detail: String, trailing: String?
  ) -> some View {
    HStack(spacing: 12) {
      Image(systemName: systemImage)
        .frame(width: 22)
        .foregroundStyle(Color.accentColor)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(title).font(.body.weight(.semibold))
          if let caption {
            Text(caption)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer(minLength: 0)
      if let trailing {
        Text(trailing)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
      }
    }
  }

  private var visibleRows: [Row] {
    search.rows(for: query, recentSettingIDs: SettingsSearchRecents.decode(storedRecents))
  }

  private func choose(_ row: Row?) {
    guard let row else { return }
    if case .setting(let entry) = row.item {
      let recents = SettingsSearchRecents.recording(entry.id, in: SettingsSearchRecents.decode(storedRecents))
      storedRecents = SettingsSearchRecents.encode(recents)
    }
    dismiss()
    onSelect(row.item)
  }
}
