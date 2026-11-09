import SpeakCore
import SwiftUI

/// ⌘F settings search: typeahead over the shared settings catalogue plus one
/// entry per API-key card. Choosing a result navigates to and highlights it.
struct SettingsSearchPalette: View {
  let onSelect: (SettingsSearchEntry) -> Void

  @Environment(\.dismiss) private var dismiss
  @AppStorage("settingsSearch.recentEntryIDs") private var storedRecents = ""
  @State private var query = ""
  @State private var selectedIndex = 0
  @State private var index = SettingsSearchIndex(entries: MacSettingsSearch.catalogEntries)
  @FocusState private var isFieldFocused: Bool

  private struct Row: Identifiable {
    let entry: SettingsSearchEntry
    let matchedKeyword: String?
    let group: String?
    var id: String { entry.id }
  }

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
      index = SettingsSearchIndex(
        entries: MacSettingsSearch.catalogEntries
          + MacSettingsSearch.apiKeyEntries(transcriptionProviders: providers)
      )
    }
  }

  private func searchField(rows: [Row]) -> some View {
    HStack(spacing: 10) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      TextField("Search settings, keys and shortcuts", text: $query)
        .textFieldStyle(.plain)
        .font(.title3)
        .focused($isFieldFocused)
        .accessibilityLabel("Search settings")
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
    index.completions(for: query, limit: 5)
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
            if let group = row.group, position == 0 || rows[position - 1].group != group {
              Text(group)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            }
            resultRow(row, isSelected: position == selectedIndex)
              .id(row.id)
          }
        }
        .listStyle(.plain)
        .accessibilityLabel(query.isEmpty ? "Recent and suggested settings" : "\(rows.count) settings found")
        .onChange(of: selectedIndex) { _, newValue in
          guard rows.indices.contains(newValue) else { return }
          proxy.scrollTo(rows[newValue].id)
        }
      }
    }
  }

  private func resultRow(_ row: Row, isSelected: Bool) -> some View {
    let entry = row.entry
    let detail = row.matchedKeyword.map { "Matches “\($0)” · \(entry.summary)" } ?? entry.summary
    return Button {
      choose(row)
    } label: {
      HStack(spacing: 12) {
        Image(systemName: entry.systemImage)
          .frame(width: 22)
          .foregroundStyle(Color.accentColor)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 6) {
            Text(entry.title).font(.body.weight(.semibold))
            if !entry.isSectionRoot {
              Text(entry.section.title)
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
      }
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
    .accessibilityLabel(entry.isSectionRoot ? "\(entry.title) settings" : "\(entry.title), \(entry.section.title)")
    .accessibilityHint(detail)
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    .accessibilityIdentifier(entry.resultAccessibilityIdentifier)
  }

  private var visibleRows: [Row] {
    guard query.trimmingCharacters(in: .whitespaces).isEmpty else {
      return index.search(query, limit: 30).map { Row(entry: $0.entry, matchedKeyword: $0.matchedKeyword, group: nil) }
    }
    let recentIDs = SettingsSearchRecents.decode(storedRecents)
    let recents = recentIDs.compactMap { index.entry(id: $0) }
    let suggested = SettingsSearchCatalog.suggestedEntryIDs
      .filter { !recentIDs.contains($0) }
      .compactMap { index.entry(id: $0) }
    return recents.map { Row(entry: $0, matchedKeyword: nil, group: "Recent") }
      + suggested.map { Row(entry: $0, matchedKeyword: nil, group: "Suggested") }
  }

  private func choose(_ row: Row?) {
    guard let row else { return }
    let recents = SettingsSearchRecents.recording(row.entry.id, in: SettingsSearchRecents.decode(storedRecents))
    storedRecents = SettingsSearchRecents.encode(recents)
    onSelect(row.entry)
    dismiss()
  }
}
