import SpeakCore
import AppKit
import SwiftUI

/// Sheet for creating or editing a single dictation profile.
struct ProfileEditorView: View {
  @Environment(\.dismiss) private var dismiss
  @ObservedObject var settings: AppSettings
  private let originalID: UUID?
  private let onSave: (DictationProfile) -> Void

  @State private var draft: ProfileEditorDraft

  init(profile: DictationProfile?, settings: AppSettings, onSave: @escaping (DictationProfile) -> Void) {
    self.settings = settings
    self.originalID = profile?.id
    self.onSave = onSave
    _draft = State(initialValue: ProfileEditorDraft(profile: profile, settings: settings))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text(originalID == nil ? "New Profile" : "Edit Profile")
          .font(.headline)
        Spacer()
        Button("Cancel") { dismiss() }
        Button("Save") {
          onSave(draft.profile(id: originalID))
          dismiss()
        }
        .buttonStyle(.borderedProminent)
        .disabled(!draft.canSave)
      }
      .padding(16)

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          VStack(alignment: .leading, spacing: 6) {
            Text("Name")
              .font(.subheadline.weight(.semibold))
            TextField("e.g. Slack, Email, Code", text: $draft.name)
              .textFieldStyle(.roundedBorder)
          }

          ProfileAppsSection(bundleIDs: $draft.bundleIDs)

          transcriptionSection
          polishSection
          languageSection
          issuesSection
        }
        .padding(16)
      }
    }
    .frame(minWidth: 560, minHeight: 620)
  }
}

// MARK: - Editor sections

extension ProfileEditorView {
  fileprivate var transcriptionSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Transcription")
        .font(.subheadline.weight(.semibold))
      Picker("Transcription", selection: $draft.transcriptionChoice) {
        ForEach(ProfileTranscriptionChoice.allCases) { choice in
          Text(choice.displayName).tag(choice)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()

      if draft.transcriptionChoice == .streaming {
        ModelPicker(
          title: "Streaming Model",
          help: "Model used while recording when this profile is active. "
            + "Custom identifiers must belong to a supported live provider.",
          options: ModelCatalog.liveTranscription,
          value: $draft.streamingModel,
          credentialPurpose: .liveTranscription,
          storedAPIKeyIdentifiers: Set(settings.trackedAPIKeyIdentifiers)
        )
      } else if draft.transcriptionChoice == .batch {
        ModelPicker(
          title: "Batch Model",
          help: "Model the finished recording is sent to when this profile is active.",
          options: ModelCatalog.batchTranscription,
          value: $draft.batchModel,
          credentialPurpose: .batchTranscription,
          storedAPIKeyIdentifiers: Set(settings.trackedAPIKeyIdentifiers)
        )
      }
    }
  }

  fileprivate var polishSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Polish (Post-processing)")
        .font(.subheadline.weight(.semibold))
      Picker("Polish", selection: $draft.polishChoice) {
        ForEach(ProfilePolishChoice.allCases) { choice in
          Text(choice.displayName).tag(choice)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()

      if draft.polishChoice == .enabled {
        // Catalogue models only: a custom identifier would be normalised away
        // at session time, so it cannot be offered here.
        ModelPicker(
          title: "Polish Model",
          help: "LLM used to clean up the transcript for this profile. "
            + "Runs after recording even when Live Polish is your usual speed mode.",
          options: ModelCatalog.postProcessing,
          value: $draft.polishModel,
          credentialPurpose: .postProcessing,
          storedAPIKeyIdentifiers: Set(settings.trackedAPIKeyIdentifiers),
          usesDetailedChooser: true,
          allowsCustom: false
        )

        if draft.usesRulesCleanup {
          Text(
            "The built-in rules cleaner fixes spacing, punctuation and capitalisation only. "
              + "It does not use prompts, an output language or lexicon directives, so those options are hidden."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        } else {
          promptControls
        }
      }
    }
  }

  fileprivate var promptControls: some View {
    Group {
      Toggle("Custom polish prompt", isOn: $draft.useCustomPrompt)
      if draft.useCustomPrompt {
        TextEditor(text: $draft.customPrompt)
          .font(.body.monospaced())
          .frame(minHeight: 120)
          .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
              .strokeBorder(Color.secondary.opacity(0.3))
          )
        Text("Replaces the built-in cleanup instructions for this profile.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Picker("Output Language", selection: $draft.outputLanguage) {
        Text("Use Default").tag("")
        ForEach(Self.outputLanguages, id: \.self) { language in
          Text(language).tag(language)
        }
      }
      .pickerStyle(.menu)

      Toggle("Include personal lexicon directives", isOn: $draft.includeLexiconDirectives)
      Toggle("Include context tags", isOn: $draft.includeContextTags)
    }
  }

  fileprivate var languageSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Spoken Language")
        .font(.subheadline.weight(.semibold))
      Picker("Spoken Language", selection: $draft.languageIdentifier) {
        Text("Use Default").tag("")
        ForEach(TranscriptionLanguageCatalog.options) { option in
          Text(option.displayName).tag(option.id)
        }
      }
      .pickerStyle(.menu)
      .labelsHidden()
    }
  }

  /// Why the profile cannot be saved yet. Shown instead of letting a
  /// configuration through that would not run as displayed.
  @ViewBuilder
  fileprivate var issuesSection: some View {
    let issues = draft.issues
    if !issues.isEmpty {
      VStack(alignment: .leading, spacing: 4) {
        ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
          Label(issue.message, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.orange)
        }
      }
      .accessibilityElement(children: .combine)
    }
  }

  fileprivate static var outputLanguages: [String] {
    [
      "English", "British English", "Spanish", "French", "German", "Italian",
      "Portuguese", "Chinese", "Japanese", "Korean", "Russian", "Arabic", "Hindi"
    ]
  }
}
