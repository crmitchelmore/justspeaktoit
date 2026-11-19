import SpeakCore
import SwiftUI

/// The new/edit correction form. The draft and focus are owned by
/// `PersonalCorrectionsView` because the saved-rules list also starts edits.
struct PersonalCorrectionEditorCard: View {
  @Environment(\.appVisualDensity) private var density
  @Binding var draft: PersonalCorrectionRuleDraft
  @Binding var showAdvancedOptions: Bool
  var focusedField: FocusState<PersonalCorrectionsView.Field?>.Binding
  let onSave: () -> Void
  let onReset: () -> Void

  var body: some View {
    SpeakDensityCard(
      title: draft.isEditing ? "Edit correction" : "New correction",
      systemImage: "square.and.pencil",
      tint: .brandAccentWarm
    ) {
      if !density.isCompact {
        Text(
          "Aliases support full words only. Automatic rules run when tags match; "
            + "manual rules stay as review-only suggestions."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      VStack(alignment: .leading, spacing: density.inlineSpacing) {
        LabeledContent("Correct spelling") {
          TextField("e.g. Susy", text: $draft.canonical)
            .textFieldStyle(.roundedBorder)
            .focused(focusedField, equals: .canonical)
        }
        LabeledContent("Heard as") {
          TextField("e.g. Susie, Suzie", text: $draft.aliasesText, axis: .vertical)
            .lineLimit(2...4)
            .textFieldStyle(.roundedBorder)
            .focused(focusedField, equals: .aliases)
        }

        DisclosureGroup("Advanced options", isExpanded: $showAdvancedOptions) {
          advancedOptions
        }
      }

      HStack(spacing: density.inlineSpacing) {
        Button(draft.isEditing ? "Update Rule" : "Add Rule", action: onSave)
          .buttonStyle(.borderedProminent)
          .disabled(!draft.isSavable)
        Button("Reset", role: .cancel, action: onReset)
          .buttonStyle(.bordered)
        if draft.isEditing {
          Text("Editing \(draft.canonicalDisplay)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
      }
    }
  }

  @ViewBuilder
  private var advancedOptions: some View {
    Picker("Activation", selection: $draft.activation) {
      ForEach(PersonalLexiconRule.Activation.allCases, id: \.self) { activation in
        Text(PersonalCorrectionLabels.label(for: activation)).tag(activation)
      }
    }
    .pickerStyle(.segmented)
    Picker("Confidence", selection: $draft.confidence) {
      ForEach(PersonalLexiconConfidence.allCases, id: \.self) { confidence in
        Text(PersonalCorrectionLabels.label(for: confidence)).tag(confidence)
      }
    }
    .pickerStyle(.segmented)
    LabeledContent("Only apply when tags match") {
      TextField("partner, project", text: $draft.contextTagsText)
        .textFieldStyle(.roundedBorder)
        .focused(focusedField, equals: .contextTags)
    }
    LabeledContent("Notes") {
      TextField("Optional context", text: $draft.notes, axis: .vertical)
        .lineLimit(1...3)
        .textFieldStyle(.roundedBorder)
        .focused(focusedField, equals: .notes)
    }
  }
}

/// The saved correction rules, each with Edit and Delete actions.
struct SavedCorrectionRulesSection: View {
  @EnvironmentObject private var lexicon: PersonalLexiconService
  @Environment(\.appVisualDensity) private var density
  let onEdit: (PersonalLexiconRule) -> Void
  let onError: (Error) -> Void

  var body: some View {
    SpeakDensityCard(title: "Saved rules", systemImage: "list.bullet.rectangle", tint: .brandAccent) {
      if lexicon.rules.isEmpty {
        Text("No corrections yet. Add your preferred spellings above.")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        LazyVStack(spacing: density.isCompact ? density.sectionSpacing : 16) {
          ForEach(lexicon.rules) { rule in
            ruleRow(rule)
          }
        }
      }
    }
  }

  private func ruleRow(_ rule: PersonalLexiconRule) -> some View {
    VStack(alignment: .leading, spacing: density.isCompact ? 4 : 10) {
      ruleHeader(rule)

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

      ruleRowActions(rule)
    }
    .padding(density.isCompact ? density.cardPadding : 20)
    .background(
      RoundedRectangle(cornerRadius: density.isCompact ? 8 : 22, style: .continuous)
        .fill(Color(nsColor: .controlBackgroundColor))
    )
  }

  private func ruleHeader(_ rule: PersonalLexiconRule) -> some View {
    HStack(alignment: .top) {
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 6) {
          Text(rule.canonical)
            .font(.headline)
          if rule.source == .automatic {
            Text("AUTO")
              .font(.caption2.bold())
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(Capsule().fill(Color.brandAccent.opacity(0.15)))
              .foregroundStyle(Color.brandAccent)
          }
        }
        if !rule.aliases.isEmpty {
          Text("Heard as: \(rule.aliases.joined(separator: ", "))")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
      }
      Spacer()
      Text(PersonalCorrectionLabels.label(for: rule.activation))
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.secondary.opacity(0.1)))
    }
  }

  private func ruleRowActions(_ rule: PersonalLexiconRule) -> some View {
    HStack(spacing: 12) {
      Button("Edit") {
        onEdit(rule)
      }
      .buttonStyle(.bordered)
      Button("Delete", role: .destructive) {
        Task {
          do {
            try await lexicon.deleteRule(id: rule.id)
          } catch {
            onError(error)
          }
        }
      }
      .buttonStyle(.bordered)
      Spacer()
      Text("Updated \(rule.updatedAt.formatted(date: .abbreviated, time: .shortened))")
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
  }
}
