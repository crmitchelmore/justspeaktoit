import AppKit
import Foundation
import SpeakCore

/// Wires the voice-edit orchestrator to the real app services: selection capture via
/// Accessibility or pasteboard, instruction capture via the normal transcription pipeline,
/// LLM rewrite via the post-processing client, and HUD feedback.
@MainActor
final class VoiceEditController {
  private let mainManager: MainManager
  private let audioFileManager: AudioFileManager
  private let transcriptionManager: TranscriptionManager
  private let rewriter: VoiceEditRewriter
  private let hudManager: HUDManager
  private let selectionService: VoiceEditSelectionService

  private var orchestrator: VoiceEditOrchestrator?
  private var pendingCapture: VoiceEditSelectionService.Capture?
  private var escapeToken: ShortcutListenerToken?

  init(
    mainManager: MainManager,
    audioFileManager: AudioFileManager,
    transcriptionManager: TranscriptionManager,
    rewriter: VoiceEditRewriter,
    hudManager: HUDManager,
    hotKeyManager: HotKeyManager,
    selectionService: VoiceEditSelectionService
  ) {
    self.mainManager = mainManager
    self.audioFileManager = audioFileManager
    self.transcriptionManager = transcriptionManager
    self.rewriter = rewriter
    self.hudManager = hudManager
    self.selectionService = selectionService
    self.orchestrator = VoiceEditOrchestrator(dependencies: makeDependencies())
    self.escapeToken = hotKeyManager.register(shortcut: .escape) { [weak self] in
      self?.orchestrator?.cancel()
    }
  }

  /// Hotkey entry point. First press captures the selection and starts listening for the
  /// spoken instruction; the second press finishes the instruction and applies the rewrite.
  func toggle() {
    Task { [weak self] in
      await self?.orchestrator?.toggle()
    }
  }

  // MARK: - Orchestrator dependencies

  private func makeDependencies() -> VoiceEditOrchestrator.Dependencies {
    VoiceEditOrchestrator.Dependencies(
      isDictationBusy: { [weak self] in
        guard let self else { return true }
        return self.mainManager.activeSession != nil || self.mainManager.isBusy
      },
      hasConfiguredLLM: { [weak self] in
        guard let self else { return false }
        return await self.rewriter.isConfigured()
      },
      captureSelection: { [weak self] in
        guard let self else { return nil }
        let capture = await self.selectionService.capture()
        self.pendingCapture = capture
        return capture?.selection
      },
      startListening: { [weak self] in
        try await self?.startListening()
      },
      finishListening: { [weak self] in
        guard let self else { return "" }
        return try await self.finishListening()
      },
      cancelListening: { [weak self] in
        self?.cancelListening()
      },
      rewrite: { [weak self] selection, instruction in
        guard let self else { throw VoiceEditControllerError.unavailable }
        return try await self.rewriter.rewrite(
          selection: selection.text,
          instruction: instruction
        )
      },
      applyReplacement: { [weak self] _, rewrittenText in
        guard let self else { return .leftOnClipboard }
        guard let capture = self.pendingCapture else {
          return self.selectionService.leaveOnClipboard(rewrittenText)
        }
        return await self.selectionService.replace(capture, with: rewrittenText)
      },
      onEvent: { [weak self] event in
        self?.handle(event)
      }
    )
  }

  // MARK: - Instruction capture

  private func startListening() async throws {
    _ = try await audioFileManager.startRecording()
    guard mainManager.isStreamingTranscriptionMode else { return }
    do {
      try await transcriptionManager.startLiveTranscription()
    } catch {
      await audioFileManager.cancelRecording()
      throw error
    }
  }

  private func finishListening() async throws -> String {
    let summary = try await audioFileManager.stopRecording()
    defer { cleanUpInstructionAudio(at: summary.url) }
    if mainManager.isStreamingTranscriptionMode {
      return try await transcriptionManager.stopLiveTranscription().text
    }
    return try await transcriptionManager.transcribeFile(at: summary.url).text
  }

  private func cancelListening() {
    if mainManager.isStreamingTranscriptionMode {
      transcriptionManager.cancelLiveTranscription()
    }
    Task { [audioFileManager] in
      await audioFileManager.cancelRecording()
    }
  }

  private func cleanUpInstructionAudio(at url: URL) {
    // Instruction clips never appear in history, so drop the backing file straight away.
    try? FileManager.default.removeItem(at: url)
  }

  // MARK: - HUD feedback

  private func handle(_ event: VoiceEditOrchestrator.Event) {
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
    case .leftOnClipboard:
      hudManager.finishFailure(
        headline: "Press ⌘V to paste",
        message: "Couldn't replace the selection automatically. The rewrite is on your clipboard."
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

private enum VoiceEditControllerError: LocalizedError {
  case unavailable

  var errorDescription: String? { "Voice edit is unavailable." }
}
