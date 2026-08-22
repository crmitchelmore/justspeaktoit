import Foundation

// MARK: - HUD feedback

extension VoiceEditController {
  func handle(_ event: VoiceEditOrchestrator.Event) {
    switch event {
    case .listeningStarted(let source):
      hudManager.beginEditing(subheadline: Self.listeningSubheadline(for: source))
    case .transcribingInstruction:
      hudManager.beginEditing(subheadline: "Understanding your instruction")
    case .rewriting:
      hudManager.beginEditing(subheadline: "Rewriting with your model")
    case .applying:
      hudManager.beginEditing(subheadline: "Applying the edit")
    case .finished(let outcome):
      pendingCapture = nil
      finish(outcome)
    case .failed(let reason):
      pendingCapture = nil
      fail(reason)
    case .cancelled:
      pendingCapture = nil
      hudManager.hide()
    }
  }

  private func finish(_ outcome: VoiceEditOrchestrator.ReplacementOutcome) {
    switch outcome {
    case .replaced, .pasted:
      hudManager.finishSuccess(message: "Edited")
    case .leftOnClipboard(let reason):
      let (headline, message) = Self.clipboardGuidance(for: reason)
      hudManager.finishFailure(headline: headline, message: message)
    }
  }

  /// Every parked rewrite ends with the same instruction — press ⌘V — but says
  /// why the edit was not applied automatically, so "Edited" is never shown
  /// for a change that did not happen.
  static func clipboardGuidance(for reason: VoiceEditClipboardReason) -> (headline: String, message: String) {
    switch reason {
    case .selectionChanged:
      return (
        "Selection changed",
        "The text moved or changed while you spoke, so nothing was replaced. "
          + "The rewrite is on your clipboard — select the text and press ⌘V."
      )
    case .selectionUnverifiable:
      return (
        "Couldn't confirm the selection",
        "This app doesn't report its selection, so nothing was replaced. "
          + "The rewrite is on your clipboard — press ⌘V where you want it."
      )
    case .targetUnavailable:
      return (
        "App no longer available",
        "The app you were editing in has gone away. The rewrite is on your clipboard — press ⌘V."
      )
    case .replacementUnverified:
      return (
        "Couldn't confirm the edit",
        "The app accepted the change but doesn't show it. The rewrite is on your clipboard — "
          + "check the text and press ⌘V if needed."
      )
    case .pasteUnverified:
      return (
        "Nothing changed",
        "The app didn't accept the paste (it may be read-only). "
          + "The rewrite is on your clipboard — press ⌘V where you want it."
      )
    case .replacementFailed, .noCapture:
      return (
        "Press ⌘V to paste",
        "Couldn't replace the selection automatically. The rewrite is on your clipboard."
      )
    }
  }

  private func fail(_ reason: VoiceEditOrchestrator.FailureReason) {
    switch reason {
    case .dictationBusy:
      hudManager.finishFailure(
        headline: "Voice edit unavailable",
        message: "Finish the current dictation first.",
        displayDuration: 3
      )
    case .noSelection:
      hudManager.finishFailure(
        headline: "Nothing to edit",
        message: "Select some text, or dictate something first, then try again.",
        displayDuration: 4
      )
    case .noConfiguredLLM:
      hudManager.finishFailure(
        headline: "No language model configured",
        message: "Voice edit uses your post-processing model. Add an OpenRouter API key in Settings › API Keys."
      )
    case .emptyInstruction:
      hudManager.finishFailure(
        headline: "No instruction heard",
        message: "Press the hotkey again and speak an instruction like \"make this shorter\".",
        displayDuration: 4
      )
    case .recordingFailed(let message):
      hudManager.finishFailure(headline: "Couldn't record instruction", message: message)
    case .transcriptionFailed(let message):
      hudManager.finishFailure(headline: "Couldn't transcribe instruction", message: message)
    case .rewriteFailed(let message):
      hudManager.finishFailure(headline: "Rewrite failed", message: message)
    }
  }

  private static func listeningSubheadline(
    for source: VoiceEditOrchestrator.SelectionSource
  ) -> String {
    switch source {
    case .accessibility, .clipboard:
      return "Speak an instruction for the selection"
    case .lastInsertion:
      return "Speak an instruction for your last dictation"
    }
  }
}
