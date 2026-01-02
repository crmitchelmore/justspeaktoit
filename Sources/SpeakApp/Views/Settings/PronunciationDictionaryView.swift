import SwiftUI
import UniformTypeIdentifiers

/// View for managing the pronunciation dictionary.
struct PronunciationDictionaryView: View {
    @EnvironmentObject private var pronunciationManager: PronunciationManager
    @State private var searchText = ""
    @State private var selectedCategory: PronunciationEntry.Category?
    @State private var showingAddSheet = false
    @State private var showingImportSheet = false
    @State private var showingExportSheet = false
    @State private var editingEntry: PronunciationEntry?
    @State private var exportURL: URL?
    @State private var importMerge = true
    @State private var alertMessage: String?
    @State private var showingAlert = false

    private var filteredEntries: [PronunciationEntry] {
        var result = pronunciationManager.entries

        // Filter by category
        if let category = selectedCategory {
            result = result.filter { $0.category == category.rawValue }
        }

        // Filter by search
        if !searchText.isEmpty {
            let lowercasedQuery = searchText.lowercased()
            result = result.filter { entry in
                entry.word.lowercased().contains(lowercasedQuery) ||
                entry.pronunciation.lowercased().contains(lowercasedQuery) ||
                (entry.replacement?.lowercased().contains(lowercasedQuery) ?? false)
            }
        }

        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header with search and actions
            headerView

            Divider()

            // Category tabs
            categoryTabsView

            // Entries list
            if filteredEntries.isEmpty {
                emptyStateView
            } else {
                entriesListView
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            PronunciationEntryFormView(
                entry: nil,
                onSave: { entry in
                    pronunciationManager.addEntry(entry)
                }
            )
        }
        .sheet(item: $editingEntry) { entry in
            PronunciationEntryFormView(
                entry: entry,
                onSave: { updatedEntry in
                    pronunciationManager.updateEntry(updatedEntry)
                }
            )
        }
        .fileImporter(
            isPresented: $showingImportSheet,
            allowedContentTypes: [UTType.json],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .fileExporter(
            isPresented: $showingExportSheet,
            document: PronunciationDocument(entries: pronunciationManager.entries),
            contentType: .json,
            defaultFilename: "pronunciation_dictionary"
        ) { result in
            handleExport(result)
        }
        .alert("Pronunciation Dictionary", isPresented: $showingAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
    }

    // MARK: - Header

    private var headerView: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Pronunciation Dictionary")
                    .font(.title2.bold())
                Spacer()
                HStack(spacing: 8) {
                    Button {
                        showingImportSheet = true
                    } label: {
                        Label("Import", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        showingExportSheet = true
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                    .disabled(pronunciationManager.entries.isEmpty)

                    Button {
                        showingAddSheet = true
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search words or pronunciations...", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
        }
        .padding()
    }

    // MARK: - Category Tabs

    private var categoryTabsView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                CategoryTab(
                    title: "All",
                    count: pronunciationManager.entries.count,
                    isSelected: selectedCategory == nil
                ) {
                    selectedCategory = nil
                }

                ForEach(PronunciationEntry.Category.allCases) { category in
                    let count = pronunciationManager.entries.filter { $0.category == category.rawValue }.count
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
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Entries List

    private var entriesListView: some View {
        List {
            ForEach(filteredEntries) { entry in
                PronunciationEntryRow(entry: entry)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        editingEntry = entry
                    }
                    .contextMenu {
                        Button {
                            editingEntry = entry
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }

                        Button(role: .destructive) {
                            pronunciationManager.deleteEntry(entry)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            pronunciationManager.deleteEntry(entry)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .swipeActions(edge: .leading) {
                        Button {
                            editingEntry = entry
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
            }
        }
        .listStyle(.inset)
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "text.book.closed")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)

            if searchText.isEmpty && selectedCategory == nil {
                Text("No pronunciation entries")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("Add custom pronunciations for words that TTS engines mispronounce.")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)

                HStack(spacing: 12) {
                    Button("Add Entry") {
                        showingAddSheet = true
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Load Defaults") {
                        pronunciationManager.resetToDefaults()
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.top, 8)
            } else {
                Text("No matching entries")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Button("Clear Search") {
                    searchText = ""
                    selectedCategory = nil
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Import/Export

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                try pronunciationManager.importFromFile(url, merge: importMerge)
                alertMessage = "Successfully imported pronunciation entries."
                showingAlert = true
            } catch {
                alertMessage = "Failed to import: \(error.localizedDescription)"
                showingAlert = true
            }
        case .failure(let error):
            alertMessage = "Import failed: \(error.localizedDescription)"
            showingAlert = true
        }
    }

    private func handleExport(_ result: Result<URL, Error>) {
        switch result {
        case .success:
            alertMessage = "Successfully exported pronunciation dictionary."
            showingAlert = true
        case .failure(let error):
            alertMessage = "Export failed: \(error.localizedDescription)"
            showingAlert = true
        }
    }
}

// MARK: - Category Tab

private struct CategoryTab: View {
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
                    .font(.subheadline.weight(isSelected ? .semibold : .regular))
                Text("\(count)")
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(isSelected ? Color.white.opacity(0.2) : Color.secondary.opacity(0.15))
                    )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(isSelected ? Color.accentColor : Color.clear)
            )
            .foregroundStyle(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Entry Row

private struct PronunciationEntryRow: View {
    let entry: PronunciationEntry

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(entry.word)
                        .font(.headline)

                    if entry.isRegex {
                        Text("REGEX")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule()
                                    .fill(Color.orange.opacity(0.2))
                            )
                            .foregroundStyle(.orange)
                    }

                    if entry.caseSensitive {
                        Text("Aa")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule()
                                    .fill(Color.blue.opacity(0.2))
                            )
                            .foregroundStyle(.blue)
                    }
                }

                HStack(spacing: 4) {
                    Image(systemName: "arrow.right")
                        .imageScale(.small)
                        .foregroundStyle(.tertiary)
                    Text(entry.pronunciation)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if let category = entry.category {
                Text(category)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Color.secondary.opacity(0.1))
                    )
                    .foregroundStyle(.secondary)
            }

            Image(systemName: "chevron.right")
                .imageScale(.small)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Entry Form

struct PronunciationEntryFormView: View {
    let entry: PronunciationEntry?
    let onSave: (PronunciationEntry) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var word: String
    @State private var pronunciation: String
    @State private var replacement: String
    @State private var category: PronunciationEntry.Category
    @State private var isRegex: Bool
    @State private var caseSensitive: Bool

    init(entry: PronunciationEntry?, onSave: @escaping (PronunciationEntry) -> Void) {
        self.entry = entry
        self.onSave = onSave

        _word = State(initialValue: entry?.word ?? "")
        _pronunciation = State(initialValue: entry?.pronunciation ?? "")
        _replacement = State(initialValue: entry?.replacement ?? "")
        _category = State(initialValue: PronunciationEntry.Category(rawValue: entry?.category ?? "") ?? .custom)
        _isRegex = State(initialValue: entry?.isRegex ?? false)
        _caseSensitive = State(initialValue: entry?.caseSensitive ?? false)
    }

    private var isValid: Bool {
        !word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !pronunciation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Spacer()

                Text(entry == nil ? "Add Entry" : "Edit Entry")
                    .font(.headline)

                Spacer()

                Button("Save") {
                    saveEntry()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isValid)
            }
            .padding()

            Divider()

            // Form
            Form {
                Section("Word") {
                    TextField("Original text", text: $word)
                        .textFieldStyle(.roundedBorder)
                    Text("The word or phrase to match in the text.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Pronunciation") {
                    TextField("How to pronounce", text: $pronunciation)
                        .textFieldStyle(.roundedBorder)
                    Text("Enter phonetic spelling or IPA notation.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Replacement (Optional)") {
                    TextField("Text replacement", text: $replacement)
                        .textFieldStyle(.roundedBorder)
                    Text("Simple text replacement for providers without SSML support.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Category") {
                    Picker("Category", selection: $category) {
                        ForEach(PronunciationEntry.Category.allCases) { cat in
                            Label(cat.rawValue, systemImage: cat.systemImage)
                                .tag(cat)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Section("Options") {
                    Toggle("Use as regex pattern", isOn: $isRegex)
                    Toggle("Case sensitive", isOn: $caseSensitive)
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 450, height: 500)
    }

    private func saveEntry() {
        let trimmedWord = word.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPronunciation = pronunciation.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedReplacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)

        let newEntry = PronunciationEntry(
            id: entry?.id ?? UUID(),
            word: trimmedWord,
            pronunciation: trimmedPronunciation,
            replacement: trimmedReplacement.isEmpty ? trimmedPronunciation : trimmedReplacement,
            category: category.rawValue,
            isRegex: isRegex,
            caseSensitive: caseSensitive
        )

        onSave(newEntry)
        dismiss()
    }
}

// MARK: - Quick Add Dialog

/// A compact dialog for quickly adding a pronunciation from context.
struct QuickAddPronunciationView: View {
    let word: String
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var pronunciation: String = ""

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Add Pronunciation")
                    .font(.headline)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Word:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(word)
                    .font(.title3.bold())
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 8) {
                Text("Pronunciation:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("How to pronounce", text: $pronunciation)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Add") {
                    onSave(pronunciation)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(pronunciation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(width: 300)
    }
}

// MARK: - Document for Export

struct PronunciationDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var entries: [PronunciationEntry]

    init(entries: [PronunciationEntry]) {
        self.entries = entries
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        entries = try JSONDecoder().decode([PronunciationEntry].self, from: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(entries)
        return FileWrapper(regularFileWithContents: data)
    }
}
