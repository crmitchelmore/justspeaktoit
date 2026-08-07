import SpeakCore
import AppKit
import SwiftUI

private enum ProfileTranscriptionChoice: String, CaseIterable, Identifiable {
  case useDefault
  case streaming
  case batch

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .useDefault: return "Use Default"
    case .streaming: return "Remote Streaming"
    case .batch: return "Remote Batch"
    }
  }
}

private enum ProfilePolishChoice: String, CaseIterable, Identifiable {
  case useDefault
  case enabled
  case disabled

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .useDefault: return "Use Default"
    case .enabled: return "Enabled"
    case .disabled: return "Disabled"
    }
  }
}

/// Sheet for creating or editing a single dictation profile.
struct ProfileEditorView: View {
  @Environment(\.dismiss) private var dismiss
  @ObservedObject var settings: AppSettings
  private let originalID: UUID?
  private let onSave: (DictationProfile) -> Void

  @State private var name: String
  @State private var bundleIDs: [String]
  @State fileprivate var transcriptionChoice: ProfileTranscriptionChoice
  @State private var streamingModel: String
  @State private var batchModel: String
  @State fileprivate var polishChoice: ProfilePolishChoice
  @State private var polishModel: String
  @State private var useCustomPrompt: Bool
  @State private var customPrompt: String
  @State private var outputLanguage: String
  @State private var includeLexiconDirectives: Bool
  @State private var includeContextTags: Bool
  @State private var languageIdentifier: String

  init(profile: DictationProfile?, settings: AppSettings, onSave: @escaping (DictationProfile) -> Void) {
    self.settings = settings
    self.originalID = profile?.id
    self.onSave = onSave

    _name = State(initialValue: profile?.name ?? "")
    _bundleIDs = State(initialValue: profile?.matchers.filter { $0.kind == .bundleID }.map(\.value) ?? [])

    let transcriptionModelID = profile?.transcriptionModelID?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let isLiveModel = ModelCatalog.liveTranscription.contains {
      $0.id.caseInsensitiveCompare(transcriptionModelID) == .orderedSame
    }
    if transcriptionModelID.isEmpty {
      _transcriptionChoice = State(initialValue: .useDefault)
      _streamingModel = State(initialValue: settings.liveTranscriptionModel)
      _batchModel = State(initialValue: settings.batchTranscriptionModel)
    } else if isLiveModel {
      _transcriptionChoice = State(initialValue: .streaming)
      _streamingModel = State(initialValue: transcriptionModelID)
      _batchModel = State(initialValue: settings.batchTranscriptionModel)
    } else {
      _transcriptionChoice = State(initialValue: .batch)
      _streamingModel = State(initialValue: settings.liveTranscriptionModel)
      _batchModel = State(initialValue: transcriptionModelID)
    }

    switch profile?.polishEnabled {
    case .some(true):
      _polishChoice = State(initialValue: .enabled)
    case .some(false):
      _polishChoice = State(initialValue: .disabled)
    case .none:
      _polishChoice = State(initialValue: .useDefault)
    }
    _polishModel = State(initialValue: profile?.polishModelID ?? settings.postProcessingModel)
    let prompt = profile?.polishPrompt ?? ""
    _useCustomPrompt = State(initialValue: !prompt.isEmpty)
    _customPrompt = State(initialValue: prompt)
    _outputLanguage = State(initialValue: profile?.polishOutputLanguage ?? "")
    _includeLexiconDirectives = State(
      initialValue: profile?.polishIncludeLexiconDirectives ?? settings.postProcessingIncludeLexiconDirectives
    )
    _includeContextTags = State(
      initialValue: profile?.polishIncludeContextTags ?? settings.postProcessingIncludeContextTags
    )
    _languageIdentifier = State(initialValue: profile?.languageIdentifier ?? "")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text(originalID == nil ? "New Profile" : "Edit Profile")
          .font(.headline)
        Spacer()
        Button("Cancel") { dismiss() }
        Button("Save") {
          onSave(builtProfile)
          dismiss()
        }
        .buttonStyle(.borderedProminent)
        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
      .padding(16)

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          VStack(alignment: .leading, spacing: 6) {
            Text("Name")
              .font(.subheadline.weight(.semibold))
            TextField("e.g. Slack, Email, Code", text: $name)
              .textFieldStyle(.roundedBorder)
          }

          ProfileAppsSection(bundleIDs: $bundleIDs)

          transcriptionSection
          polishSection
          languageSection
        }
        .padding(16)
      }
    }
    .frame(minWidth: 560, minHeight: 620)
  }

  fileprivate var builtProfile: DictationProfile {
    let polishEnabled: Bool?
    switch polishChoice {
    case .useDefault: polishEnabled = nil
    case .enabled: polishEnabled = true
    case .disabled: polishEnabled = false
    }

    let transcriptionModelID: String?
    switch transcriptionChoice {
    case .useDefault:
      transcriptionModelID = nil
    case .streaming:
      transcriptionModelID = normalized(streamingModel)
    case .batch:
      transcriptionModelID = normalized(batchModel)
    }

    let isPolishOverridden = polishChoice == .enabled
    return DictationProfile(
      id: originalID ?? UUID(),
      name: name.trimmingCharacters(in: .whitespacesAndNewlines),
      matchers: bundleIDs.map(DictationProfileMatcher.bundleID),
      transcriptionModelID: transcriptionModelID,
      polishEnabled: polishEnabled,
      polishModelID: isPolishOverridden ? normalized(polishModel) : nil,
      polishPrompt: isPolishOverridden && useCustomPrompt ? normalized(customPrompt) : nil,
      polishOutputLanguage: isPolishOverridden ? normalized(outputLanguage) : nil,
      polishIncludeLexiconDirectives: isPolishOverridden ? includeLexiconDirectives : nil,
      polishIncludeContextTags: isPolishOverridden ? includeContextTags : nil,
      languageIdentifier: normalized(languageIdentifier)
    )
  }

  private func normalized(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

// MARK: - Editor sections

extension ProfileEditorView {
  fileprivate var transcriptionSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Transcription")
        .font(.subheadline.weight(.semibold))
      Picker("Transcription", selection: $transcriptionChoice) {
        ForEach(ProfileTranscriptionChoice.allCases) { choice in
          Text(choice.displayName).tag(choice)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()

      if transcriptionChoice == .streaming {
        ModelPicker(
          title: "Streaming Model",
          help: "Model used while recording when this profile is active.",
          options: ModelCatalog.liveTranscription,
          value: $streamingModel,
          credentialPurpose: .liveTranscription,
          storedAPIKeyIdentifiers: Set(settings.trackedAPIKeyIdentifiers)
        )
      } else if transcriptionChoice == .batch {
        ModelPicker(
          title: "Batch Model",
          help: "Model the finished recording is sent to when this profile is active.",
          options: ModelCatalog.batchTranscription,
          value: $batchModel,
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
      Picker("Polish", selection: $polishChoice) {
        ForEach(ProfilePolishChoice.allCases) { choice in
          Text(choice.displayName).tag(choice)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()

      if polishChoice == .enabled {
        ModelPicker(
          title: "Polish Model",
          help: "LLM used to clean up the transcript for this profile.",
          options: ModelCatalog.postProcessing,
          value: $polishModel,
          credentialPurpose: .postProcessing,
          storedAPIKeyIdentifiers: Set(settings.trackedAPIKeyIdentifiers),
          usesDetailedChooser: true
        )

        Toggle("Custom polish prompt", isOn: $useCustomPrompt)
        if useCustomPrompt {
          TextEditor(text: $customPrompt)
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

        Picker("Output Language", selection: $outputLanguage) {
          Text("Use Default").tag("")
          ForEach(Self.outputLanguages, id: \.self) { language in
            Text(language).tag(language)
          }
        }
        .pickerStyle(.menu)

        Toggle("Include personal lexicon directives", isOn: $includeLexiconDirectives)
        Toggle("Include context tags", isOn: $includeContextTags)
      }
    }
  }

  fileprivate var languageSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Spoken Language")
        .font(.subheadline.weight(.semibold))
      Picker("Spoken Language", selection: $languageIdentifier) {
        Text("Use Default").tag("")
        ForEach(TranscriptionLanguageCatalog.options) { option in
          Text(option.displayName).tag(option.id)
        }
      }
      .pickerStyle(.menu)
      .labelsHidden()
    }
  }

  fileprivate static var outputLanguages: [String] {
    [
      "English", "British English", "Spanish", "French", "German", "Italian",
      "Portuguese", "Chinese", "Japanese", "Korean", "Russian", "Arabic", "Hindi"
    ]
  }
}
