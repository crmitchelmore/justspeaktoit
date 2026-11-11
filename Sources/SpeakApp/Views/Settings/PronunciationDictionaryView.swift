import SpeakCore
import SwiftUI
import UniformTypeIdentifiers

/// View for managing the pronunciation dictionary.
struct PronunciationDictionaryView: View {
    @Environment(\.appVisualDensity) private var density
    @EnvironmentObject private var pronunciationManager: PronunciationManager
    @State private var searchText = ""
    @State private var selectedCategory: PronunciationEntry.Category?
    @State private var showingAddSheet = false
    @State private var showingImportSheet = false
    @State private var showingExportSheet = false
    @State private var editingEntry: PronunciationEntry?
    @State private var importMerge = true
    @State private var alertMessage: String?
    @State private var showingAlert = false
    @State private var entryPendingDeletion: PronunciationEntry?

    private var filteredEntries: [PronunciationEntry] {
        PronunciationEntryFilter.entries(
            pronunciationManager.entries,
            category: selectedCategory,
            searchText: searchText
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header with search and actions
            PronunciationDictionaryHeader(
                searchText: $searchText,
                canExport: !pronunciationManager.entries.isEmpty,
                onImport: { showingImportSheet = true },
                onExport: { showingExportSheet = true },
                onAdd: { showingAddSheet = true }
            )

            Divider()

            // Category tabs
            PronunciationCategoryTabs(
                entries: pronunciationManager.entries,
                selectedCategory: $selectedCategory
            )

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
        .confirmationDialog(
            "Delete Entry",
            isPresented: Binding(
                get: { entryPendingDeletion != nil },
                set: { if !$0 { entryPendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: entryPendingDeletion
        ) { entry in
            Button("Delete", role: .destructive) {
                pronunciationManager.deleteEntry(entry)
                entryPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                entryPendingDeletion = nil
            }
        } message: { entry in
            Text("Are you sure you want to delete the entry for \"\(entry.word)\"? This cannot be undone.")
        }
    }

    // MARK: - Entries List

    private var entriesListView: some View {
        LazyVGrid(
            columns: entryColumns,
            alignment: .leading,
            spacing: density.isCompact ? density.sectionSpacing : 8
        ) {
            ForEach(filteredEntries) { entry in
                Button {
                    editingEntry = entry
                } label: {
                    PronunciationEntryRow(entry: entry)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the editor for this entry.")
                .contextMenu {
                    Button {
                        editingEntry = entry
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }

                    Button(role: .destructive) {
                        entryPendingDeletion = entry
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .padding(.horizontal, density.isCompact ? 8 : 16)
        .padding(.bottom, density.isCompact ? 8 : 16)
    }

    private var entryColumns: [GridItem] {
        if density.isCompact {
            return [
                GridItem(
                    .adaptive(minimum: 260, maximum: 380),
                    spacing: density.sectionSpacing,
                    alignment: .top
                )
            ]
        }
        return [GridItem(.flexible(), alignment: .top)]
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
        .frame(maxWidth: .infinity)
        .frame(minHeight: 260)
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
