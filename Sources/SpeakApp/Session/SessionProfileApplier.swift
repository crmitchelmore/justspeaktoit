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
///
/// Every override remembers the value it replaced and the value it set. `end`
/// restores a setting only while it still holds the applied value: a change
/// the user made in Settings during the session is theirs and is kept,
/// together with the persistence its own setter already performed (issue #690,
/// coordinating with #642).
@MainActor
final class SessionProfileApplier {
  /// One setting the profile changed, with the knowledge to undo it.
  private struct Override {
    let name: String
    /// Restores the original value; false when the session changed the setting again.
    let restore: (AppSettings) -> Bool
  }

  /// Name of the profile applied to the current session, for HUD display.
  private(set) var activeProfileName: String?
  private var overrides: [Override] = []
  private let log = SpeakLogger.logger(category: "SessionProfileApplier")

  /// Resolves the profile for the frontmost app and applies its overrides.
  /// A `nil` resolution leaves every setting untouched (the default profile).
  func begin(
    settings: AppSettings,
    postProcessing: PostProcessingManager,
    profiles: [DictationProfile],
    frontmostBundleID: String?
  ) {
    // Never stack overrides: restore any leftover overrides first.
    end(settings: settings, postProcessing: postProcessing)
    let resolver = ProfileResolver(profiles: profiles)
    guard let profile = resolver.profile(forBundleID: frontmostBundleID) else { return }

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
    guard !overrides.isEmpty else { return }
    let pending = overrides
    overrides = []

    settings.suppressesPersistence = true
    defer { settings.suppressesPersistence = false }
    // Restore order matters: the transcription selection first so the speed
    // mode is judged against the user's own model, the speed mode next, and
    // `postProcessingEnabled` last because its setter rejects `true` while a
    // speed mode other than instant is active.
    for override in pending where !override.restore(settings) {
      log.info("Kept \(override.name, privacy: .public): changed during the session")
    }
  }

  // MARK: - Applying

  private func apply(
    _ profile: DictationProfile,
    to settings: AppSettings,
    postProcessing: PostProcessingManager
  ) {
    settings.suppressesPersistence = true
    defer { settings.suppressesPersistence = false }

    // Speed mode and polish can be disturbed by the setters of every
    // transcription field, so their originals are captured before anything
    // is applied and they are restored last.
    let originalSpeedMode = settings.speedMode
    let originalPolishEnabled = settings.postProcessingEnabled

    if let override = profile.resolvedTranscriptionOverride {
      applyTranscriptionModel(override.modelID, routing: override.routing, to: settings)
    }
    if let language = normalized(profile.languageIdentifier) {
      set(\.preferredLocaleIdentifier, to: language, on: settings, name: "preferredLocaleIdentifier")
    }
    applyPolish(profile, to: settings, postProcessing: postProcessing)

    if profile.polishEnabled == true {
      // Profile polish means end-of-session post-processing, which only the
      // instant speed mode allows; a live-polish session would silently reject
      // it. Session-only, like every other override.
      settings.speedMode = .instant
    }
    if let polishEnabled = profile.polishEnabled {
      settings.postProcessingEnabled = polishEnabled
    }
    track(\.speedMode, original: originalSpeedMode, on: settings, name: "speedMode")
    track(\.postProcessingEnabled, original: originalPolishEnabled, on: settings, name: "postProcessingEnabled")
  }

  private func applyPolish(
    _ profile: DictationProfile,
    to settings: AppSettings,
    postProcessing: PostProcessingManager
  ) {
    var polishModel: String?
    if let requested = normalized(profile.polishModelID) {
      if DictationProfileValidator.isSupportedPolishModel(requested) {
        polishModel = requested
        set(\.postProcessingModel, to: requested, on: settings, name: "postProcessingModel")
      } else {
        log.error(
          """
          Profile "\(profile.name, privacy: .public)" names polish model \(requested, privacy: .public), \
          which the app cannot run; keeping the user's model
          """)
      }
    }

    // The built-in rules cleaner ignores prompts, output language and lexicon
    // directives, so none of them is applied for it.
    let effectiveModel = polishModel ?? settings.postProcessingModel
    guard effectiveModel != LocalPostProcessingModelManager.builtInRulesModelID else {
      postProcessing.sessionPromptOverride = nil
      return
    }
    if let outputLanguage = normalized(profile.polishOutputLanguage) {
      set(\.postProcessingOutputLanguage, to: outputLanguage, on: settings, name: "postProcessingOutputLanguage")
    }
    if let includeDirectives = profile.polishIncludeLexiconDirectives {
      set(
        \.postProcessingIncludeLexiconDirectives, to: includeDirectives, on: settings,
        name: "postProcessingIncludeLexiconDirectives"
      )
    }
    if let includeTags = profile.polishIncludeContextTags {
      set(\.postProcessingIncludeContextTags, to: includeTags, on: settings, name: "postProcessingIncludeContextTags")
    }
    postProcessing.sessionPromptOverride = normalized(profile.polishPrompt)
  }

  /// Applies the model to the slot its routing names. Explicit routing comes
  /// from the editor; older profiles derive it from the identifier.
  private func applyTranscriptionModel(
    _ modelID: String,
    routing: DictationProfileTranscriptionRouting,
    to settings: AppSettings
  ) {
    switch routing {
    case .remoteStreaming:
      set(\.transcriptionMode, to: .liveNative, on: settings, name: "transcriptionMode")
      set(\.liveTranscriptionModel, to: modelID, on: settings, name: "liveTranscriptionModel")
    case .remoteBatch:
      set(\.transcriptionMode, to: .batchRemote, on: settings, name: "transcriptionMode")
      set(\.batchTranscriptionModel, to: modelID, on: settings, name: "batchTranscriptionModel")
    case .localBatch:
      set(\.transcriptionMode, to: .localModel, on: settings, name: "transcriptionMode")
      set(\.localTranscriptionMode, to: .batch, on: settings, name: "localTranscriptionMode")
      set(\.localTranscriptionModel, to: modelID, on: settings, name: "localTranscriptionModel")
    }
  }

  // MARK: - Override bookkeeping

  /// Sets a value and records how to undo it. The recorded "applied" value is
  /// read back after the set, so a setter that normalises its input is still
  /// matched correctly at restore time.
  private func set<Value: Equatable>(
    _ keyPath: ReferenceWritableKeyPath<AppSettings, Value>,
    to value: Value,
    on settings: AppSettings,
    name: String
  ) {
    let original = settings[keyPath: keyPath]
    settings[keyPath: keyPath] = value
    track(keyPath, original: original, on: settings, name: name)
  }

  /// Records an undo for a setting whose current value is the session value,
  /// whether it was set directly or moved by another setter's invariant.
  private func track<Value: Equatable>(
    _ keyPath: ReferenceWritableKeyPath<AppSettings, Value>,
    original: Value,
    on settings: AppSettings,
    name: String
  ) {
    let applied = settings[keyPath: keyPath]
    overrides.append(
      Override(name: name) { settings in
        guard settings[keyPath: keyPath] == applied else { return false }
        settings[keyPath: keyPath] = original
        return true
      }
    )
  }

  private func normalized(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
      return nil
    }
    return trimmed
  }
}
