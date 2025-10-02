import SwiftUI

struct PersonalCorrectionsView: View {
  @EnvironmentObject private var lexicon: PersonalLexiconService
  @State private var draft = RuleDraft()
  @State private var alertMessage: String?
  @State private var previewText: String = "Hey love, Susie and I will join the meeting at 3pm."
  @FocusState private var focusedField: Field?

  enum Field: Hashable {
    case displayName
    case canonical
    case aliases
    case contextTags
    case notes
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 28) {
        hero
        editorCard
        existingRulesSection
        previewSection
      }
      .padding(24)
      .frame(maxWidth: 960, alignment: .leading)
    }
    .background(
      LinearGradient(colors: [Color.pink.opacity(0.08), .clear], startPoint: .top, endPoint: .center)
    )
    .alert("Unable to Save", isPresented: Binding<Bool>(
      get: { alertMessage != nil },
      set: { if !$0 { alertMessage = nil } }
    )) {
      Button("OK", role: .cancel) { alertMessage = nil }
    } message: {
      Text(alertMessage ?? "An unknown error occurred.")
    }
  }

  private var hero: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Corrections")
        .font(.largeTitle.bold())
      Text(
        "Teach Speak how your world sounds. Define preferred spellings and let the app correct transcripts when the context fits without leaking private names."
      )
      .font(.title3)
      .foregroundStyle(.secondary)
      HStack(spacing: 20) {
        Label("Automatic when context matches", systemImage: "checkmark.seal.fill")
          .labelStyle(.titleAndIcon)
          .foregroundStyle(.green)
        Label("Manual rules stay as suggestions", systemImage: "hand.raised")
          .labelStyle(.titleAndIcon)
          .foregroundStyle(.orange)
      }
      .font(.callout)
    }
    .padding(32)
    .background(
      RoundedRectangle(cornerRadius: 28, style: .continuous)
        .fill(
          LinearGradient(
            colors: [Color.pink.opacity(0.35), Color.purple.opacity(0.2)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          )
        )
    )
    .overlay(
      RoundedRectangle(cornerRadius: 28, style: .continuous)
        .stroke(Color.pink.opacity(0.3), lineWidth: 1)
    )
  }

  private var editorCard: some View {
    VStack(alignment: .leading, spacing: 20) {
      headerRow

      VStack(alignment: .leading, spacing: 12) {
        TextField("Display name", text: $draft.displayName)
          .textFieldStyle(.roundedBorder)
          .focused($focusedField, equals: Field.displayName)
        TextField("Canonical spelling", text: $draft.canonical)
          .textFieldStyle(.roundedBorder)
          .focused($focusedField, equals: Field.canonical)
        TextField("Spoken variants (comma or newline separated)", text: $draft.aliasesText, axis: .vertical)
          .lineLimit(2...4)
          .textFieldStyle(.roundedBorder)
          .focused($focusedField, equals: Field.aliases)
        Picker("Activation", selection: $draft.activation) {
          ForEach(PersonalLexiconRule.Activation.allCases, id: \.self) { activation in
            Text(label(for: activation)).tag(activation)
          }
        }
        .pickerStyle(.segmented)
        Picker("Confidence", selection: $draft.confidence) {
          ForEach(PersonalLexiconConfidence.allCases, id: \.self) { confidence in
            Text(label(for: confidence)).tag(confidence)
          }
        }
        .pickerStyle(.segmented)
        TextField("Context tags (comma separated, e.g. partner, meeting)", text: $draft.contextTagsText)
          .textFieldStyle(.roundedBorder)
          .focused($focusedField, equals: Field.contextTags)
        TextField("Notes", text: $draft.notes, axis: .vertical)
          .lineLimit(1...3)
          .textFieldStyle(.roundedBorder)
          .focused($focusedField, equals: Field.notes)
      }

      HStack(spacing: 12) {
        Button(draft.isEditing ? "Update Rule" : "Add Rule", action: saveDraft)
          .buttonStyle(.borderedProminent)
          .disabled(!draft.isSavable)
        Button("Reset", role: .cancel, action: resetDraft)
          .buttonStyle(.bordered)
        if draft.isEditing {
          Text("Editing \(draft.displayName)")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        Spacer()
      }
    }
    .padding(28)
    .background(
      RoundedRectangle(cornerRadius: 26, style: .continuous)
        .fill(.ultraThinMaterial)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 26, style: .continuous)
        .stroke(Color.pink.opacity(0.15), lineWidth: 1)
    )
  }

  private var headerRow: some View {
    HStack(alignment: .top) {
      VStack(alignment: .leading, spacing: 6) {
        Text(draft.isEditing ? "Edit correction" : "New correction")
          .font(.title3.bold())
        Text(
          "Aliases support full words only. Automatic rules run when tags match; manual rules stay as review-only suggestions."
        )
        .foregroundStyle(.secondary)
        .font(.footnote)
      }
      Spacer()
    }
  }

  private var existingRulesSection: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Saved rules")
        .font(.title3.bold())
      if lexicon.rules.isEmpty {
        Text("No corrections yet. Add your preferred spellings above.")
          .foregroundStyle(.secondary)
          .italic()
      } else {
        LazyVStack(spacing: 16) {
          ForEach(lexicon.rules) { rule in
            ruleRow(rule)
          }
        }
      }
    }
  }

  private func ruleRow(_ rule: PersonalLexiconRule) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text(rule.displayName)
            .font(.headline)
          Text(rule.canonical)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Text(label(for: rule.activation))
          .font(.caption)
          .padding(.horizontal, 10)
          .padding(.vertical, 4)
          .background(Capsule().fill(Color.secondary.opacity(0.1)))
      }

      if !rule.aliases.isEmpty {
        HStack(spacing: 6) {
          Text("Aliases:")
            .font(.caption.bold())
          Text(rule.aliases.joined(separator: ", "))
            .font(.caption)
        }
      }

      if !rule.contextTags.isEmpty {
        HStack(spacing: 6) {
          Text("Tags:")
            .font(.caption.bold())
          Text(rule.contextTags.sorted().joined(separator: ", "))
            .font(.caption)
        }
      }

      if let notes = rule.notes, !notes.isEmpty {
        Text(notes)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      HStack(spacing: 12) {
        Button("Edit") {
          draft = RuleDraft(rule: rule)
          focusedField = .displayName
        }
        .buttonStyle(.bordered)
        Button("Delete", role: .destructive) {
          Task { await lexicon.deleteRule(id: rule.id) }
        }
        .buttonStyle(.bordered)
        Spacer()
        Text("Updated \(rule.updatedAt.formatted(date: .abbreviated, time: .shortened))")
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
    }
    .padding(20)
    .background(
      RoundedRectangle(cornerRadius: 22, style: .continuous)
        .fill(Color(nsColor: .controlBackgroundColor))
    )
  }

  private var previewSection: some View {
    let context = PersonalLexiconContext(tags: draft.previewTags, destinationApplication: "Preview", recentTranscriptWindow: previewText)
    let preview = lexicon.apply(to: previewText, context: context)

    return VStack(alignment: .leading, spacing: 16) {
      Text("Preview")
        .font(.title3.bold())
      TextEditor(text: $previewText)
        .frame(minHeight: 120)
        .padding(12)
        .background(
          RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color(nsColor: .textBackgroundColor))
        )
      VStack(alignment: .leading, spacing: 8) {
        Text("Transformed")
          .font(.caption.bold())
        Text(preview.transformedText)
          .padding(12)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
              .fill(Color(nsColor: .underPageBackgroundColor))
          )
      }

      if !preview.applied.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
          Text("Applied corrections")
            .font(.caption.bold())
          ForEach(preview.applied, id: \.id) { record in
            correctionRow(record)
          }
        }
      }

      if !preview.suggestions.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
          Text("Suggestions")
            .font(.caption.bold())
          ForEach(preview.suggestions, id: \.id) { record in
            correctionRow(record)
          }
        }
      }
    }
    .padding(24)
    .background(
      RoundedRectangle(cornerRadius: 24, style: .continuous)
        .fill(.ultraThinMaterial)
    )
  }

  private func correctionRow(_ record: PersonalLexiconCorrectionRecord) -> some View {
    HStack(spacing: 8) {
      Image(systemName: record.wasApplied ? "wand.and.stars" : "questionmark.circle")
        .foregroundStyle(record.wasApplied ? Color.green : Color.orange)
      VStack(alignment: .leading, spacing: 2) {
        Text("\(record.alias) -> \(record.canonical) (\(record.occurrences)x)")
          .font(.caption)
        if let reason = record.reason {
          Text(reason)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
      Spacer()
      Text(label(for: record.confidence))
        .font(.caption2)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.secondary.opacity(0.12)))
    }
  }

  private func saveDraft() {
    guard draft.isSavable else { return }
    let aliases = draft.aliases
    let tags = draft.tags
    let notes = draft.notes.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedNotes = notes.isEmpty ? nil : notes

    if let ruleID = draft.id, let existing = lexicon.rules.first(where: { $0.id == ruleID }) {
      let updated = PersonalLexiconRule(
        id: existing.id,
        displayName: draft.displayName,
        canonical: draft.canonical,
        aliases: aliases,
        activation: draft.activation,
        contextTags: tags,
        confidence: draft.confidence,
        notes: trimmedNotes,
        createdAt: existing.createdAt,
        updatedAt: Date()
      )
      Task {
        do {
          try await lexicon.updateRule(updated)
          resetDraft()
        } catch {
          alertMessage = error.localizedDescription
        }
      }
    } else {
      Task {
        do {
          _ = try await lexicon.addRule(
            displayName: draft.displayName,
            canonical: draft.canonical,
            aliases: aliases,
            activation: draft.activation,
            contextTags: tags,
            confidence: draft.confidence,
            notes: trimmedNotes
          )
          resetDraft()
        } catch {
          alertMessage = error.localizedDescription
        }
      }
    }
  }

  private func resetDraft() {
    draft = RuleDraft()
    focusedField = nil
  }

  private func label(for activation: PersonalLexiconRule.Activation) -> String {
    switch activation {
    case .automatic:
      return "Automatic"
    case .requireContextMatch:
      return "Context match"
    case .manual:
      return "Manual"
    }
  }

  private func label(for confidence: PersonalLexiconConfidence) -> String {
    switch confidence {
    case .high:
      return "High"
    case .medium:
      return "Medium"
    case .low:
      return "Low"
    }
  }
}

private struct RuleDraft {
  var id: UUID?
  var displayName: String = ""
  var canonical: String = ""
  var aliasesText: String = ""
  var activation: PersonalLexiconRule.Activation = .automatic
  var contextTagsText: String = ""
  var confidence: PersonalLexiconConfidence = .high
  var notes: String = ""

  var isEditing: Bool { id != nil }

  var aliases: [String] {
    tokenize(aliasesText)
  }

  var tags: Set<String> {
    Set(tokenize(contextTagsText))
  }

  var isSavable: Bool {
    !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !canonical.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !aliases.isEmpty
  }

  var previewTags: Set<String> {
    tags
  }

  init() {}

  init(rule: PersonalLexiconRule) {
    id = rule.id
    displayName = rule.displayName
    canonical = rule.canonical
    aliasesText = rule.aliases.joined(separator: ", ")
    activation = rule.activation
    contextTagsText = rule.contextTags.sorted().joined(separator: ", ")
    confidence = rule.confidence
    notes = rule.notes ?? ""
  }
}

private func tokenize(_ text: String) -> [String] {
  text
    .split(whereSeparator: { ",\n".contains($0) })
    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    .filter { !$0.isEmpty }
}
