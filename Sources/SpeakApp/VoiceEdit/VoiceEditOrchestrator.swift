import Foundation
import SpeakCore

/// Drives the voice-edit flow: capture selection → record spoken instruction → LLM rewrite →
/// replace the selection in place.
///
/// All side effects (Accessibility reads, audio recording, transcription, LLM calls, HUD
/// updates) go through `Dependencies` closures so the state machine is unit-testable without
/// Accessibility, audio, or network access.
@MainActor
final class VoiceEditOrchestrator {
  enum Phase: Equatable {
    case idle
    /// Recording the spoken instruction; the captured selection is held.
    case listening
    /// Transcribing the instruction, rewriting, or applying the replacement.
    case processing
  }

  enum SelectionSource: Equatable {
    /// Read directly from the focused element's AX selected-text attribute.
    case accessibility
    /// Captured by simulating ⌘C into a saved-and-restored pasteboard.
    case clipboard
    /// No live selection; falling back to the last inserted transcription.
    case lastInsertion
  }

  struct Selection: Equatable {
    let text: String
    let source: SelectionSource
  }

  enum ReplacementOutcome: Equatable {
    /// The selection was replaced via Accessibility and verified.
    case replaced
    /// The rewrite was pasted over the selection via a simulated ⌘V.
    case pasted
    /// Automatic replacement failed; the rewrite was left on the clipboard for manual ⌘V.
    case leftOnClipboard
  }

  enum FailureReason: Equatable {
    case dictationBusy
    case noSelection
    case noConfiguredLLM
    case emptyInstruction
    case recordingFailed(String)
    case transcriptionFailed(String)
    case rewriteFailed(String)
  }

  enum Event: Equatable {
    case listeningStarted(SelectionSource)
    case transcribingInstruction
    case rewriting
    case applying
    case finished(ReplacementOutcome)
    case failed(FailureReason)
    case cancelled
  }

  struct Dependencies {
    var isDictationBusy: () -> Bool
    var hasConfiguredLLM: () async -> Bool
    var captureSelection: () async -> Selection?
    var startListening: () async throws -> Void
    var finishListening: () async throws -> String
    var cancelListening: () -> Void
    var rewrite: (_ selection: Selection, _ instruction: String) async throws -> String
    var applyReplacement: (_ selection: Selection, _ rewrite: String) async -> ReplacementOutcome
    var onEvent: (Event) -> Void
  }

  private(set) var phase: Phase = .idle
  private var selection: Selection?
  private let dependencies: Dependencies

  init(dependencies: Dependencies) {
    self.dependencies = dependencies
  }

  /// Hotkey entry point: starts an edit session, or finishes the listening stage.
  /// Ignored while a previous session is still processing.
  func toggle() async {
    switch phase {
    case .idle:
      await begin()
    case .listening:
      await finish()
    case .processing:
      break
    }
  }

  /// Cancels an in-flight listening session (Escape). No-op in other phases.
  func cancel() {
    guard phase == .listening else { return }
    dependencies.cancelListening()
    selection = nil
    phase = .idle
    dependencies.onEvent(.cancelled)
  }

  // MARK: - Private

  private func begin() async {
    guard !dependencies.isDictationBusy() else {
      dependencies.onEvent(.failed(.dictationBusy))
      return
    }
    guard await dependencies.hasConfiguredLLM() else {
      dependencies.onEvent(.failed(.noConfiguredLLM))
      return
    }
    guard let captured = await dependencies.captureSelection(), !captured.text.isEmpty else {
      dependencies.onEvent(.failed(.noSelection))
      return
    }
    do {
      try await dependencies.startListening()
    } catch {
      dependencies.onEvent(.failed(.recordingFailed(error.localizedDescription)))
      return
    }
    selection = captured
    phase = .listening
    dependencies.onEvent(.listeningStarted(captured.source))
  }

  private func finish() async {
    guard let captured = selection else {
      phase = .idle
      return
    }
    phase = .processing
    dependencies.onEvent(.transcribingInstruction)

    let instruction: String
    do {
      instruction = VoiceEditPolicy.normalizedInstruction(try await dependencies.finishListening())
    } catch {
      complete(with: .failed(.transcriptionFailed(error.localizedDescription)))
      return
    }
    guard !instruction.isEmpty else {
      complete(with: .failed(.emptyInstruction))
      return
    }

    dependencies.onEvent(.rewriting)
    let rewritten: String
    do {
      rewritten = try await dependencies.rewrite(captured, instruction)
    } catch {
      complete(with: .failed(.rewriteFailed(error.localizedDescription)))
      return
    }
    guard !rewritten.isEmpty else {
      complete(with: .failed(.rewriteFailed("The model returned an empty rewrite.")))
      return
    }

    dependencies.onEvent(.applying)
    let outcome = await dependencies.applyReplacement(captured, rewritten)
    complete(with: .finished(outcome))
  }

  private func complete(with event: Event) {
    selection = nil
    phase = .idle
    dependencies.onEvent(event)
  }
}
