import Foundation
import SpeakCore
import os.log

/// Applies a dictation profile's overrides to `AppSettings` for the duration of
/// a single session and restores the user's own values afterwards.
///
/// All profile-override resolution lives here: `MainManager` calls `begin` at
/// the session-start choke point and `end` whenever the session finishes (any
/// path). Overrides are applied with persistence suppressed, so a session-only
/// profile never touches the stored defaults.
@MainActor
final class SessionProfileApplier {
  private struct Snapshot {
    let transcriptionMode: AppSettings.TranscriptionMode
    let liveTranscriptionModel: String
    let batchTranscriptionModel: String
    let localTranscriptionModel: String
    let localTranscriptionMode: AppSettings.LocalTranscriptionMode
    let speedMode: AppSettings.SpeedMode
    let postProcessingEnabled: Bool
    let postProcessingModel: String
    let postProcessingOutputLanguage: String
    let postProcessingIncludeLexiconDirectives: Bool
    let postProcessingIncludeContextTags: Bool
    let preferredLocaleIdentifier: String
  }

  /// Name of the profile applied to the current session, for HUD display.
  private(set) var activeProfileName: String?
  private var snapshot: Snapshot?
  private let log = Logger(subsystem: "com.github.speakapp", category: "SessionProfileApplier")

  /// Resolves the profile for the frontmost app and applies its overrides.
  /// A `nil` resolution leaves every setting untouched (the default profile).
  func begin(
    settings: AppSettings,
    postProcessing: PostProcessingManager,
    profiles: [DictationProfile],
    frontmostBundleID: String?
  ) {
    // Never stack overrides: restore any leftover snapshot first.
    end(settings: settings, postProcessing: postProcessing)
    let resolver = ProfileResolver(profiles: profiles)
    guard let profile = resolver.profile(forBundleID: frontmostBundleID) else { return }

    snapshot = Snapshot(
      transcriptionMode: settings.transcriptionMode,
      liveTranscriptionModel: settings.liveTranscriptionModel,
      batchTranscriptionModel: settings.batchTranscriptionModel,
      localTranscriptionModel: settings.localTranscriptionModel,
      localTranscriptionMode: settings.localTranscriptionMode,
      speedMode: settings.speedMode,
      postProcessingEnabled: settings.postProcessingEnabled,
      postProcessingModel: settings.postProcessingModel,
      postProcessingOutputLanguage: settings.postProcessingOutputLanguage,
      postProcessingIncludeLexiconDirectives: settings.postProcessingIncludeLexiconDirectives,
      postProcessingIncludeContextTags: settings.postProcessingIncludeContextTags,
      preferredLocaleIdentifier: settings.preferredLocaleIdentifier
    )
    activeProfileName = profile.name
    apply(profile, to: settings, postProcessing: postProcessing)
    let bundleID = frontmostBundleID ?? "unknown"
    log.info("Applied dictation profile \"\(profile.name, privacy: .public)\" for \(bundleID, privacy: .public)")
  }

  /// Restores the user's own settings. Safe to call repeatedly; a call without
  /// an active override is a no-op.
  func end(settings: AppSettings, postProcessing: PostProcessingManager) {
    postProcessing.sessionPromptOverride = nil
    activeProfileName = nil
    guard let snapshot else { return }
    self.snapshot = nil

    settings.suppressesPersistence = true
    defer { settings.suppressesPersistence = false }
    settings.transcriptionMode = snapshot.transcriptionMode
    settings.liveTranscriptionModel = snapshot.liveTranscriptionModel
    settings.batchTranscriptionModel = snapshot.batchTranscriptionModel
    settings.localTranscriptionModel = snapshot.localTranscriptionModel
    settings.localTranscriptionMode = snapshot.localTranscriptionMode
    settings.preferredLocaleIdentifier = snapshot.preferredLocaleIdentifier
    settings.speedMode = snapshot.speedMode
    settings.postProcessingModel = snapshot.postProcessingModel
    settings.postProcessingOutputLanguage = snapshot.postProcessingOutputLanguage
    settings.postProcessingIncludeLexiconDirectives = snapshot.postProcessingIncludeLexiconDirectives
    settings.postProcessingIncludeContextTags = snapshot.postProcessingIncludeContextTags
    // Last: the didSet invariant can reject `true` while a speed mode is
    // active, so restore it after the speed mode is back.
    settings.postProcessingEnabled = snapshot.postProcessingEnabled
  }

  private func apply(
    _ profile: DictationProfile,
    to settings: AppSettings,
    postProcessing: PostProcessingManager
  ) {
    settings.suppressesPersistence = true
    defer { settings.suppressesPersistence = false }

    if let modelID = normalized(profile.transcriptionModelID) {
      applyTranscriptionModel(modelID, to: settings)
    }
    if let language = normalized(profile.languageIdentifier) {
      settings.preferredLocaleIdentifier = language
    }
    if let polishEnabled = profile.polishEnabled {
      settings.postProcessingEnabled = polishEnabled
    }
    if let model = normalized(profile.polishModelID) {
      settings.postProcessingModel = model
    }
    if let outputLanguage = normalized(profile.polishOutputLanguage) {
      settings.postProcessingOutputLanguage = outputLanguage
    }
    if let includeDirectives = profile.polishIncludeLexiconDirectives {
      settings.postProcessingIncludeLexiconDirectives = includeDirectives
    }
    if let includeTags = profile.polishIncludeContextTags {
      settings.postProcessingIncludeContextTags = includeTags
    }
    postProcessing.sessionPromptOverride = normalized(profile.polishPrompt)
  }

  /// Derives the transcription mode from the catalog identifier and applies it
  /// to the matching model slot.
  private func applyTranscriptionModel(_ modelID: String, to settings: AppSettings) {
    let isLiveModel = ModelCatalog.liveTranscription.contains {
      $0.id.caseInsensitiveCompare(modelID) == .orderedSame
    }
    if isLiveModel {
      settings.transcriptionMode = .liveNative
      settings.liveTranscriptionModel = modelID
    } else if modelID.lowercased().hasPrefix("local/") {
      settings.transcriptionMode = .localModel
      settings.localTranscriptionMode = .batch
      settings.localTranscriptionModel = modelID
    } else {
      settings.transcriptionMode = .batchRemote
      settings.batchTranscriptionModel = modelID
    }
  }

  private func normalized(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
      return nil
    }
    return trimmed
  }
}
