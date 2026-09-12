import AppKit
import Foundation
import SpeakCore

/// Wires the voice-edit orchestrator to the real app services: selection capture via
/// Accessibility or pasteboard, instruction capture via the normal transcription pipeline,
/// LLM rewrite via the post-processing client, and HUD feedback.
@MainActor
final class VoiceEditController {
  let mainManager: MainManager
  private let audioFileManager: AudioFileManager
  private let transcriptionManager: TranscriptionManager
  private let rewriter: VoiceEditRewriter
  let hudManager: HUDManager
  private let selectionService: VoiceEditSelectionService
  private let replacementService: VoiceEditReplacementService

  let hotKeyManager: HotKeyManager

  private var orchestrator: VoiceEditOrchestrator?
  var pendingCapture: VoiceEditSelectionService.Capture?
  private var escapeToken: ShortcutListenerToken?

  init(
    mainManager: MainManager,
    audioFileManager: AudioFileManager,
    transcriptionManager: TranscriptionManager,
    rewriter: VoiceEditRewriter,
    hudManager: HUDManager,
    hotKeyManager: HotKeyManager,
    selectionService: VoiceEditSelectionService,
    replacementService: VoiceEditReplacementService
  ) {
    self.mainManager = mainManager
    self.audioFileManager = audioFileManager
    self.transcriptionManager = transcriptionManager
    self.rewriter = rewriter
    self.hudManager = hudManager
    self.selectionService = selectionService
    self.replacementService = replacementService
    self.hotKeyManager = hotKeyManager
    self.orchestrator = VoiceEditOrchestrator(dependencies: makeDependencies())
    self.escapeToken = hotKeyManager.register(shortcut: .escape) { [weak self] in
      Task { @MainActor [weak self] in
        await self?.orchestrator?.cancel()
      }
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
      reserveCapture: { [weak self] in
        self?.mainManager.captureOwnership.reserve(.voiceEdit) ?? false
      },
      releaseCapture: { [weak self] in
        self?.mainManager.captureOwnership.release(.voiceEdit)
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
        await self?.cancelListening()
      },
      rewrite: { [weak self] selection, instruction in
        guard let self else { throw VoiceEditControllerError.unavailable }
        return try await self.rewriter.rewrite(
          selection: selection.text,
          instruction: instruction
        )
      },
      applyReplacement: { [weak self] _, rewrittenText in
        guard let self else { return .leftOnClipboard(.noCapture) }
        guard let capture = self.pendingCapture else {
          return self.replacementService.leaveOnClipboard(rewrittenText)
        }
        return await self.replacementService.replace(capture, with: rewrittenText)
      },
      onEvent: { [weak self] event in
        self?.handle(event)
      }
    )
  }

  // MARK: - Instruction capture

  private func startListening() async throws {
    _ = try await audioFileManager.startRecording(owner: .voiceEdit)
    guard mainManager.isStreamingTranscriptionMode else { return }
    do {
      try await transcriptionManager.startLiveTranscription()
    } catch {
      await audioFileManager.cancelRecording(ifOwnedBy: .voiceEdit)
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

  /// Awaited by the orchestrator, so Escape returns to idle only after the recorder has
  /// actually been released and a rapid restart cannot hit `alreadyRecording`.
  private func cancelListening() async {
    if mainManager.isStreamingTranscriptionMode {
      transcriptionManager.cancelLiveTranscription()
    }
    await audioFileManager.cancelRecording(ifOwnedBy: .voiceEdit)
  }

  private func cleanUpInstructionAudio(at url: URL) {
    // Instruction clips never appear in history, so drop the backing file straight away.
    try? FileManager.default.removeItem(at: url)
  }
}

enum VoiceEditControllerError: LocalizedError {
  case unavailable

  var errorDescription: String? { "Voice edit is unavailable." }
}
