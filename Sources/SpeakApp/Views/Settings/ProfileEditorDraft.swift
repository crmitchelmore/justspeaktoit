import Foundation
import SpeakCore

enum ProfileTranscriptionChoice: String, CaseIterable, Identifiable {
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

  /// The routing stored with the profile, so the applier never has to guess.
  var routing: DictationProfileTranscriptionRouting? {
    switch self {
    case .useDefault: return nil
    case .streaming: return .remoteStreaming
    case .batch: return .remoteBatch
    }
  }

  init(routing: DictationProfileTranscriptionRouting?) {
    switch routing {
    case .none: self = .useDefault
    case .remoteStreaming: self = .streaming
    case .remoteBatch, .localBatch: self = .batch
    }
  }
}

enum ProfilePolishChoice: String, CaseIterable, Identifiable {
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

/// The editable state behind `ProfileEditorView`, kept as a value so the
/// save-time rules — what is stored, what is dropped, what blocks saving —
/// are unit-testable without SwiftUI (issue #690).
struct ProfileEditorDraft: Equatable {
  var name = ""
  var bundleIDs: [String] = []
  var transcriptionChoice: ProfileTranscriptionChoice = .useDefault
  var streamingModel = ""
  var batchModel = ""
  var polishChoice: ProfilePolishChoice = .useDefault
  var polishModel = ""
  var useCustomPrompt = false
  var customPrompt = ""
  var outputLanguage = ""
  var includeLexiconDirectives = false
  var includeContextTags = false
  var languageIdentifier = ""

  init() {}

  @MainActor
  init(profile: DictationProfile?, settings: AppSettings) {
    name = profile?.name ?? ""
    bundleIDs = profile?.matchers.filter { $0.kind == .bundleID }.map(\.value) ?? []

    streamingModel = settings.liveTranscriptionModel
    batchModel = settings.batchTranscriptionModel
    if let override = profile?.resolvedTranscriptionOverride {
      transcriptionChoice = ProfileTranscriptionChoice(routing: override.routing)
      switch override.routing {
      case .remoteStreaming: streamingModel = override.modelID
      case .remoteBatch, .localBatch: batchModel = override.modelID
      }
    }

    switch profile?.polishEnabled {
    case .some(true): polishChoice = .enabled
    case .some(false): polishChoice = .disabled
    case .none: polishChoice = .useDefault
    }
    polishModel = profile?.polishModelID ?? settings.postProcessingModel
    let prompt = profile?.polishPrompt ?? ""
    useCustomPrompt = !prompt.isEmpty
    customPrompt = prompt
    outputLanguage = profile?.polishOutputLanguage ?? ""
    includeLexiconDirectives = profile?.polishIncludeLexiconDirectives
      ?? settings.postProcessingIncludeLexiconDirectives
    includeContextTags = profile?.polishIncludeContextTags ?? settings.postProcessingIncludeContextTags
    languageIdentifier = profile?.languageIdentifier ?? ""
  }

  /// Whether the chosen polish model is the built-in rules cleaner, which
  /// fixes spacing, punctuation and capitalisation only and ignores prompts,
  /// output language and lexicon directives.
  var usesRulesCleanup: Bool {
    polishChoice == .enabled
      && polishModel.trimmingCharacters(in: .whitespacesAndNewlines)
        == LocalPostProcessingModelManager.builtInRulesModelID
  }

  var issues: [DictationProfileIssue] {
    DictationProfileValidator.issues(for: profile(id: nil))
  }

  var canSave: Bool { issues.isEmpty }

  /// The profile exactly as the editor displays it: controls that are hidden
  /// for the chosen model are not stored, so nothing can apply silently.
  func profile(id: UUID?) -> DictationProfile {
    let polishEnabled: Bool?
    switch polishChoice {
    case .useDefault: polishEnabled = nil
    case .enabled: polishEnabled = true
    case .disabled: polishEnabled = false
    }

    let transcriptionModelID: String?
    switch transcriptionChoice {
    case .useDefault: transcriptionModelID = nil
    case .streaming: transcriptionModelID = Self.normalized(streamingModel)
    case .batch: transcriptionModelID = Self.normalized(batchModel)
    }

    let isPolishOverridden = polishChoice == .enabled
    let storesPromptControls = isPolishOverridden && !usesRulesCleanup
    return DictationProfile(
      id: id ?? UUID(),
      name: name.trimmingCharacters(in: .whitespacesAndNewlines),
      matchers: bundleIDs.map(DictationProfileMatcher.bundleID),
      transcriptionModelID: transcriptionModelID,
      polishEnabled: polishEnabled,
      polishModelID: isPolishOverridden ? Self.normalized(polishModel) : nil,
      polishPrompt: storesPromptControls && useCustomPrompt ? Self.normalized(customPrompt) : nil,
      polishOutputLanguage: storesPromptControls ? Self.normalized(outputLanguage) : nil,
      polishIncludeLexiconDirectives: storesPromptControls ? includeLexiconDirectives : nil,
      polishIncludeContextTags: storesPromptControls ? includeContextTags : nil,
      languageIdentifier: Self.normalized(languageIdentifier),
      transcriptionRouting: transcriptionModelID == nil ? nil : transcriptionChoice.routing
    )
  }

  private static func normalized(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
