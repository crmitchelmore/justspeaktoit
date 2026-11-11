import SpeakCore
import SwiftUI

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
                .keyboardShortcut(.cancelAction)

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
                .accessibilityLabel("Close")
                .accessibilityIdentifier("pronunciationQuickAddClose")
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
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Add") {
                    onSave(pronunciation)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(pronunciation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(width: 300)
    }
}
