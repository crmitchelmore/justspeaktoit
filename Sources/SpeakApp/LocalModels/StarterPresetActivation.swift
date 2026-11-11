import Foundation

/// Sequences the "Configure and Download" action for local-model starter presets.
///
/// A preset becomes the active recording configuration only after its model is
/// ready. While a download runs, the last usable setup stays active. A newer
/// request supersedes an older one, so a late completion cannot replace the
/// setup that the user selected last.
@MainActor
enum StarterPresetActivation {
  /// Prepares the model behind a preset, then activates the preset.
  ///
  /// - Parameters:
  ///   - isReady: `true` when the model is already installed.
  ///   - pending: The activation from a previous request. This function cancels it.
  ///   - prepare: Downloads and prepares the model. It returns `true` only when
  ///     the model is ready to use.
  ///   - activate: Commits the preset as the active recording configuration.
  /// - Returns: The activation task, or `nil` when the preset activates immediately.
  @discardableResult
  static func configureAndDownload(
    isReady: Bool,
    supersedes pending: Task<Void, Never>?,
    prepare: @escaping @MainActor () async -> Bool,
    activate: @escaping @MainActor () -> Void
  ) -> Task<Void, Never>? {
    pending?.cancel()

    guard !isReady else {
      activate()
      return nil
    }

    return Task { @MainActor in
      let isPrepared = await prepare()
      guard !Task.isCancelled, isPrepared else { return }
      activate()
    }
  }
}
