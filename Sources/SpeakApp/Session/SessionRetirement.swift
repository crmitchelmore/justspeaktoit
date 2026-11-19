import Foundation

/// What has to happen when a dictation session stops being the active one.
///
/// `MainManager` hands every ended session here: each teardown path clears
/// `activeSession`, and clearing it calls `retire(_:)`. A start rejected before
/// any session existed calls `abandonStart()` instead, because nothing was
/// reserved yet. Keeping the steps in one place fixes their order:
///
/// 1. A local automation capture tells the waiting Shortcuts action it ended.
/// 2. The per-app profile is reverted to the user's own settings.
/// 3. Capture pre-warming may resume.
/// 4. The `.dictation` capture reservation is given back (Voice Edit may start).
/// 5. The key-down microphone primer may rebuild its standby engine.
@MainActor
final class SessionRetirement {
  struct Steps {
    var finishAutomationCapture: (UUID) -> Void
    var restoreProfile: () -> Void
    var resumeCaptureWarming: () -> Void
    var releaseDictationCapture: () -> Void
    var resumeKeyPressPriming: () -> Void
  }

  private let steps: Steps

  init(steps: Steps) {
    self.steps = steps
  }

  /// Runs every step for the session that just ended. `ended` is nil when the
  /// active session was already clear; the remaining steps still run, as each
  /// is safe to repeat.
  func retire(_ ended: ActiveSession?) {
    if let ended, ended.isLocalAutomationCapture {
      steps.finishAutomationCapture(ended.id)
    }
    steps.restoreProfile()
    steps.resumeCaptureWarming()
    steps.releaseDictationCapture()
    steps.resumeKeyPressPriming()
  }

  /// Undoes a start that was rejected before a session was created: only the
  /// profile and the warm-capture hand-off had been taken.
  func abandonStart() {
    steps.restoreProfile()
    steps.resumeCaptureWarming()
  }
}
