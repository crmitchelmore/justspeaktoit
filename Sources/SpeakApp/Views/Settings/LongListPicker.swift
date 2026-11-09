import SwiftUI

struct LongListChoice<ID: Hashable>: Identifiable {
    let id: ID
    let title: String
}

private struct LongListEntry<Item, ID: Hashable>: Identifiable {
    let id: ID
    let item: Item
}

enum LongListPickerPolicy {
    static let threshold = 20

    static func usesSheet(count: Int, threshold: Int = LongListPickerPolicy.threshold) -> Bool {
        count > threshold
    }
}

struct LongListPickerItems<Item, ID: Hashable> {
    struct Group: Identifiable {
        let title: String
        let items: [Item]
        var id: String { title }
    }

    let items: [Item]
    let id: (Item) -> ID

    func pinned(selection: ID) -> Item? {
        items.first { id($0) == selection }
    }

    func groups(
        selection: ID,
        query: String,
        searchText: (Item) -> [String],
        group: ((Item) -> String)?,
        includes: (Item) -> Bool = { _ in true }
    ) -> [Group] {
        let terms = query.lowercased().split(whereSeparator: { $0.isWhitespace })
        let matches = items.filter { item in
            guard id(item) != selection, includes(item) else { return false }
            let text = searchText(item).joined(separator: " ").lowercased()
            return terms.allSatisfy { text.contains($0) }
        }
        guard let group else { return matches.isEmpty ? [] : [Group(title: "", items: matches)] }
        return Dictionary(grouping: matches, by: group).map { Group(title: $0.key, items: $0.value) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}

struct LongListPicker<Item, ID: Hashable, Row: View>: View {
    let title: String
    let items: [Item]
    let id: (Item) -> ID
    @Binding var selection: ID
    let searchText: (Item) -> [String]
    var group: ((Item) -> String)?
    var threshold = LongListPickerPolicy.threshold
    var alwaysUsesSheet = false
    var includes: (Item) -> Bool = { _ in true }
    var controls: () -> AnyView = { AnyView(EmptyView()) }
    var clearFilters: () -> Void = {}
    var onOpen: () -> Void = {}
    var selectedLabel: ((Item) -> AnyView)?
    var accessory: (Item) -> AnyView = { _ in AnyView(EmptyView()) }
    var menuDividerAfter: (Item) -> Bool = { _ in false }
    @ViewBuilder let row: (Item) -> Row

    @State private var showsChooser = false

    var body: some View {
        if alwaysUsesSheet || LongListPickerPolicy.usesSheet(count: items.count, threshold: threshold) {
            Button {
                onOpen()
                showsChooser = true
            } label: {
                HStack {
                    if let current = items.first(where: { id($0) == selection }) {
                        if let selectedLabel { selectedLabel(current) } else { row(current) }
                    } else {
                        Text(title)
                    }
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            .accessibilityLabel(title)
            .accessibilityValue(items.first(where: { id($0) == selection }).map { searchText($0).first ?? title } ?? title)
            .sheet(isPresented: $showsChooser) {
                LongListChooserSheet(
                    title: title, items: items, id: id, selection: $selection,
                    searchText: searchText, group: group, includes: includes,
                    controls: controls, clearFilters: clearFilters, accessory: accessory, row: row
                )
            }
        } else {
            Picker(title, selection: $selection) {
                ForEach(items.map { LongListEntry(id: id($0), item: $0) }) { entry in
                    row(entry.item).tag(entry.id)
                    if menuDividerAfter(entry.item) { Divider() }
                }
            }
            .pickerStyle(.menu)
        }
    }
}

struct LongListChooserSheet<Item, ID: Hashable, Row: View>: View {
    let title: String
    let items: [Item]
    let id: (Item) -> ID
    @Binding var selection: ID
    let searchText: (Item) -> [String]
    var group: ((Item) -> String)?
    var includes: (Item) -> Bool = { _ in true }
    var controls: () -> AnyView = { AnyView(EmptyView()) }
    var clearFilters: () -> Void = {}
    var accessory: (Item) -> AnyView = { _ in AnyView(EmptyView()) }
    var footer: (@escaping (ID) -> Void) -> AnyView = { _ in AnyView(EmptyView()) }
    @ViewBuilder let row: (Item) -> Row

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var catalog: LongListPickerItems<Item, ID> { LongListPickerItems(items: items, id: id) }

    private var groups: [LongListPickerItems<Item, ID>.Group] {
        catalog.groups(selection: selection, query: query, searchText: searchText, group: group, includes: includes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }
            controls()
            List {
                if let current = catalog.pinned(selection: selection) {
                    Section("Current selection") { choice(current) }
                }
                if groups.isEmpty {
                    ContentUnavailableView {
                        Label("No matching results", systemImage: "magnifyingglass")
                    } description: {
                        Text("Try a different search or clear your filters.")
                    } actions: {
                        Button("Clear filters") {
                            query = ""
                            clearFilters()
                        }
                    }
                }
                ForEach(groups) { section in
                    if group != nil {
                        Section("\(section.title) (\(section.items.count))") {
                            ForEach(section.items.map { LongListEntry(id: id($0), item: $0) }) { entry in
                                choice(entry.item)
                            }
                        }
                    } else {
                        ForEach(section.items.map { LongListEntry(id: id($0), item: $0) }) { entry in
                            choice(entry.item)
                        }
                    }
                }
                footer(select)
            }
            .searchable(text: $query)
        }
        .padding(16)
        .frame(minWidth: 780, minHeight: 520)
    }

    private func choice(_ item: Item) -> some View {
        HStack(spacing: 10) {
            Button {
                select(id(item))
            } label: {
                HStack {
                    row(item)
                    Spacer()
                    if id(item) == selection {
                        Image(systemName: "checkmark").accessibilityLabel("Selected")
                    }
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
                .accessibilityElement(children: .combine)
            }
            .buttonStyle(.plain)
            accessory(item)
        }
    }

    private func select(_ value: ID) {
        selection = value
        dismiss()
    }
}
