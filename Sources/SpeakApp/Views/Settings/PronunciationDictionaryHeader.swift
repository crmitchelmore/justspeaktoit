import SpeakCore
import SwiftUI

/// The dictionary title, search field and Import/Export/Add actions, laid out
/// inline for compact density and stacked otherwise.
struct PronunciationDictionaryHeader: View {
    @Environment(\.appVisualDensity) private var density
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Binding var searchText: String
    let canExport: Bool
    let onImport: () -> Void
    let onExport: () -> Void
    let onAdd: () -> Void

    var body: some View {
        Group {
            if density.prefersInlineLayout(dynamicTypeSize: dynamicTypeSize) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: density.inlineSpacing) {
                        compactHeaderTitle
                        searchField
                        compactHeaderActions
                    }

                    VStack(alignment: .leading, spacing: density.inlineSpacing) {
                        HStack(spacing: density.inlineSpacing) {
                            compactHeaderTitle
                            Spacer(minLength: 0)
                            compactHeaderActions
                        }
                        searchField
                    }
                }
            } else {
                VStack(spacing: 12) {
                    HStack {
                        Text("Pronunciation Dictionary")
                            .font(.title2.bold())
                        Spacer()
                        regularHeaderActions
                    }
                    searchField
                }
            }
        }
        .padding(density.isCompact ? 8 : 16)
    }

    private var compactHeaderTitle: some View {
        Label("Dictionary", systemImage: "text.book.closed")
            .font(.caption.weight(.semibold))
            .fixedSize()
    }

    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search words or pronunciations…", text: $searchText)
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
                .accessibilityIdentifier("pronunciationClearSearch")
            }
        }
        .padding(density.isCompact ? 5 : 8)
        .frame(minWidth: density.isCompact ? 220 : nil, maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private var compactHeaderActions: some View {
        HStack(spacing: density.inlineSpacing) {
            Button {
                onImport()
            } label: {
                Label("Import", systemImage: "square.and.arrow.down")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
            .speakTooltip("Import pronunciation entries.")

            Button {
                onExport()
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
            .disabled(!canExport)
            .speakTooltip("Export pronunciation entries.")

            Button {
                onAdd()
            } label: {
                Label("Add", systemImage: "plus")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderedProminent)
            .speakTooltip("Add a pronunciation entry.")
        }
        .fixedSize()
    }

    private var regularHeaderActions: some View {
        HStack(spacing: 8) {
            Button {
                onImport()
            } label: {
                Label("Import", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.bordered)

            Button {
                onExport()
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.bordered)
            .disabled(!canExport)

            Button {
                onAdd()
            } label: {
                Label("Add", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

/// "All" plus one tab per category that has entries.
struct PronunciationCategoryTabs: View {
    @Environment(\.appVisualDensity) private var density
    let entries: [PronunciationEntry]
    @Binding var selectedCategory: PronunciationEntry.Category?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                CategoryTab(
                    title: "All",
                    count: entries.count,
                    isSelected: selectedCategory == nil
                ) {
                    selectedCategory = nil
                }

                ForEach(PronunciationEntry.Category.allCases) { category in
                    let count = entries.filter { $0.category == category.rawValue }.count
                    if count > 0 {
                        CategoryTab(
                            title: category.rawValue,
                            count: count,
                            systemImage: category.systemImage,
                            isSelected: selectedCategory == category
                        ) {
                            selectedCategory = category
                        }
                    }
                }
            }
            .padding(.horizontal, density.isCompact ? 8 : 16)
            .padding(.vertical, density.isCompact ? 4 : 8)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct CategoryTab: View {
    @Environment(\.appVisualDensity) private var density
    let title: String
    let count: Int
    var systemImage: String?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage = systemImage {
                    Image(systemName: systemImage)
                        .imageScale(.small)
                }
                Text(title)
                    .font(
                        density.isCompact
                            ? .caption2.weight(isSelected ? .semibold : .regular)
                            : .subheadline.weight(isSelected ? .semibold : .regular)
                    )
                Text("\(count)")
                    .font(density.isCompact ? .caption2 : .caption)
                    .padding(.horizontal, density.isCompact ? 4 : 6)
                    .padding(.vertical, density.isCompact ? 1 : 2)
                    .background(
                        Capsule()
                            .fill(isSelected ? Color.white.opacity(0.2) : Color.secondary.opacity(0.15))
                    )
            }
            .padding(.horizontal, density.isCompact ? 7 : 12)
            .padding(.vertical, density.isCompact ? 3 : 6)
            .background(
                Capsule()
                    .fill(isSelected ? Color.accentColor : Color.clear)
            )
            .foregroundStyle(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }
}
