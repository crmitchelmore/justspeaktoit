import SpeakCore
import SwiftUI

/// The Corrections page. It owns the rule draft, its focus and the save alert;
/// each card is a subview that reports failures back through `showError`.
struct PersonalCorrectionsView: View {
  @EnvironmentObject private var lexicon: PersonalLexiconService
  @Environment(\.appVisualDensity) private var density
  @State private var draft = PersonalCorrectionRuleDraft()
  @State private var alertMessage: String?
  @State private var showAdvancedOptions: Bool = false
  @FocusState private var focusedField: Field?

  enum Field: Hashable {
    case canonical
    case aliases
    case contextTags
    case notes
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: density.isCompact ? density.sectionSpacing : 28) {
        hero
        AutoCorrectionsSection(onError: showError)
        postProcessingInfoBanner
        PersonalCorrectionEditorCard(
          draft: $draft,
          showAdvancedOptions: $showAdvancedOptions,
          focusedField: $focusedField,
          onSave: saveDraft,
          onReset: resetDraft
        )
        SavedCorrectionRulesSection(onEdit: beginEditing, onError: showError)
        PersonalCorrectionsPreviewSection(previewTags: draft.previewTags)
      }
      .padding(density.pagePadding)
      .frame(maxWidth: 1100, alignment: .center)
    }
    .background(
      LinearGradient(colors: [Color.brandAccentWarm.opacity(0.08), .clear], startPoint: .top, endPoint: .center)
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

  @ViewBuilder
  private var hero: some View {
    if density.isCompact {
      HStack(spacing: density.groupSpacing) {
        Label("Corrections", systemImage: "text.badge.checkmark")
          .font(.subheadline.bold())
        Spacer(minLength: 4)
        Label("Automatic when context matches", systemImage: "checkmark.seal.fill")
          .labelStyle(.iconOnly)
          .foregroundStyle(.green)
          .speakTooltip("Automatic when context matches")
        Label("Manual rules stay as suggestions", systemImage: "hand.raised")
          .labelStyle(.iconOnly)
          .foregroundStyle(.orange)
          .speakTooltip("Manual rules stay as suggestions")
      }
      .padding(density.cardPadding)
      .foregroundStyle(.white)
      .background(
        LinearGradient(
          colors: [Color.brandAccentWarm, Color.brandAccent.opacity(0.85)],
          startPoint: .leading,
          endPoint: .trailing
        ),
        in: RoundedRectangle(cornerRadius: density.cardCornerRadius, style: .continuous)
      )
    } else {
      VStack(alignment: .leading, spacing: 16) {
        Text("Corrections")
          .font(.largeTitle.bold())
        Text(
          "Teach Speak how your world sounds. Define preferred spellings and let the app "
            + "correct transcripts when the context fits without leaking private names."
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
        LinearGradient(
          colors: [Color.brandAccentWarm, Color.brandAccent.opacity(0.85)],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        )
        .cornerRadius(32)
        .shadow(color: Color.brandAccentWarm.opacity(0.28), radius: 24, x: 0, y: 12)
      )
    }
  }

  private var postProcessingInfoBanner: some View {
    HStack(alignment: .top, spacing: density.groupSpacing) {
      Image(systemName: "info.circle.fill")
        .font(density.isCompact ? .caption : .title2)
        .foregroundStyle(Color.brandLagoon)
      VStack(alignment: .leading, spacing: density.isCompact ? 1 : 8) {
        Text("How corrections work")
          .font(density.isCompact ? .caption.weight(.semibold) : .headline)
        if !density.isCompact {
          VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
              Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .imageScale(.small)
              Text("Corrections are always applied directly to transcripts based on your rules")
                .font(.callout)
            }
            HStack(alignment: .top, spacing: 8) {
              Image(systemName: "sparkles")
                .foregroundStyle(Color.brandAccent)
                .imageScale(.small)
              Text(
                "When post-processing is enabled, your correction rules are also shared "
                  + "with the LLM for enhanced context"
              )
              .font(.callout)
            }
            HStack(alignment: .top, spacing: 8) {
              Image(systemName: "doc.plaintext")
                .foregroundStyle(.orange)
                .imageScale(.small)
              Text(
                "When post-processing is disabled, corrections still apply "
                  + "but without LLM context enhancement"
              )
              .font(.callout)
            }
          }
        } else {
          Text("Rules apply locally and can also guide post-processing.")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
    }
    .padding(density.isCompact ? density.cardPadding : 20)
    .background(
      RoundedRectangle(cornerRadius: density.isCompact ? 8 : 16, style: .continuous)
        .fill(Color.brandLagoon.opacity(0.08))
    )
    .overlay(
      RoundedRectangle(cornerRadius: density.isCompact ? 8 : 16, style: .continuous)
        .stroke(Color.brandLagoon.opacity(0.2), lineWidth: 1)
    )
  }

  private func beginEditing(_ rule: PersonalLexiconRule) {
    draft = PersonalCorrectionRuleDraft(rule: rule)
    showAdvancedOptions = draft.requiresAdvancedOptions
    focusedField = .canonical
  }

  private func showError(_ error: Error) {
    alertMessage = error.localizedDescription
  }

  private func saveDraft() {
    guard draft.isSavable else { return }
    let draft = draft

    if let ruleID = draft.id, let existing = lexicon.rules.first(where: { $0.id == ruleID }) {
      let updated = draft.updatedRule(from: existing, updatedAt: Date())
      Task {
        do {
          try await lexicon.updateRule(updated)
          resetDraft()
        } catch {
          showError(error)
        }
      }
    } else {
      Task {
        do {
          _ = try await lexicon.addRule(
            displayName: draft.generatedDisplayName,
            canonical: draft.canonical,
            aliases: draft.aliases,
            activation: draft.activation,
            contextTags: draft.tags,
            confidence: draft.confidence,
            notes: draft.trimmedNotes
          )
          resetDraft()
        } catch {
          showError(error)
        }
      }
    }
  }

  private func resetDraft() {
    draft = PersonalCorrectionRuleDraft()
    showAdvancedOptions = false
    focusedField = nil
  }
}
