#if os(macOS)
import Foundation
import SpeakCore

/// Bridges automation commands onto the same managers the UI drives.
///
/// Deliberately thin: it owns argument validation that needs the filesystem and
/// the mapping from app types onto the wire types, and nothing else. Dictation
/// start/stop and file transcription reuse the existing session and provider
/// pipelines so an automation session behaves exactly like a hotkey session.
@MainActor
final class AppAutomationHandler: AutomationCommandHandling {
  private let main: MainManager
  private let history: HistoryManager
  private let transcription: TranscriptionManager
  private let appVersion: String

  /// How long `start_dictation` waits for the session to come up before
  /// reporting what it sees. Session start does permission checks and provider
  /// warm-up, so an immediate return would usually report "not started" for a
  /// session that is about to run.
  private static let startConfirmationTimeout: TimeInterval = 5
  private static let startPollInterval: Duration = .milliseconds(50)

  init(
    main: MainManager,
    history: HistoryManager,
    transcription: TranscriptionManager,
    appVersion: String
  ) {
    self.main = main
    self.history = history
    self.transcription = transcription
    self.appVersion = appVersion
  }

  func handle(_ request: AutomationRequest) async -> AutomationResponse {
    do {
      switch request.command {
      case .status:
        return .success(id: request.id, command: request.command, result: self.status())
      case .history:
        return .success(
          id: request.id,
          command: request.command,
          result: AutomationResult(entries: self.historyEntries(limit: request.resolvedLimit))
        )
      case .transcribeFile:
        return .success(
          id: request.id,
          command: request.command,
          result: try await self.transcribeFile(request)
        )
      case .startDictation:
        return .success(id: request.id, command: request.command, result: try await self.startDictation())
      case .stopDictation:
        return .success(id: request.id, command: request.command, result: try await self.stopDictation())
      }
    } catch let error as AutomationError {
      return .failure(id: request.id, command: request.command, error: error)
    } catch {
      // Provider errors carry URLs and occasionally request context; surface the
      // localized description only, never the underlying payload.
      return .failure(
        id: request.id,
        command: request.command,
        error: AutomationError(code: .internalError, message: error.localizedDescription)
      )
    }
  }

  // MARK: - Commands

  private func status() -> AutomationResult {
    AutomationResult(
      sessionActive: self.main.activeSession != nil,
      appVersion: self.appVersion
    )
  }

  private func historyEntries(limit: Int) -> [AutomationHistoryEntry] {
    self.history.items.prefix(limit).map { item in
      let text = item.postProcessedTranscription?.isEmpty == false
        ? item.postProcessedTranscription ?? ""
        : item.rawTranscription ?? ""
      return AutomationHistoryEntry(
        id: item.id.uuidString,
        text: text,
        createdAt: item.createdAt,
        model: item.modelUsages.first?.modelIdentifier ?? item.modelsUsed.first,
        durationSeconds: item.recordingDuration,
        wordCount: text.split(whereSeparator: \.isWhitespace).count
      )
    }
  }

  private func transcribeFile(_ request: AutomationRequest) async throws -> AutomationResult {
    guard let path = request.path else {
      throw AutomationError(code: .invalidArgument, message: "transcribe_file requires a file path.")
    }
    let url = URL(fileURLWithPath: path)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
      !isDirectory.boolValue else {
      throw AutomationError(code: .fileNotFound, message: "No audio file at \(url.lastPathComponent).")
    }
    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    guard size <= AutomationLimits.maxAudioFileBytes else {
      throw AutomationError(
        code: .fileTooLarge,
        message: "\(url.lastPathComponent) is larger than the "
          + "\(AutomationLimits.maxAudioFileBytes / (1024 * 1024)) MB automation limit."
      )
    }

    do {
      let result = try await self.transcription.transcribeFile(at: url)
      return AutomationResult(
        text: result.text,
        model: result.modelIdentifier,
        durationSeconds: result.duration
      )
    } catch {
      throw AutomationError(code: .transcriptionFailed, message: error.localizedDescription)
    }
  }

  private func startDictation() async throws -> AutomationResult {
    guard self.main.activeSession == nil else {
      throw AutomationError(
        code: .alreadyRecording,
        message: "A dictation session is already running. Stop it before starting another."
      )
    }
    self.main.toggleRecordingFromUI()

    let deadline = Date().addingTimeInterval(Self.startConfirmationTimeout)
    while Date() < deadline {
      if self.main.activeSession != nil {
        return AutomationResult(sessionActive: true)
      }
      if case .failed(let message) = self.main.state {
        throw AutomationError(code: .transcriptionFailed, message: message)
      }
      try? await Task.sleep(for: Self.startPollInterval)
    }
    throw AutomationError(
      code: .timedOut,
      message: "Dictation did not start within \(Int(Self.startConfirmationTimeout))s. "
        + "Check microphone permission in the app."
    )
  }

  private func stopDictation() async throws -> AutomationResult {
    guard self.main.activeSession != nil else {
      throw AutomationError(code: .notRecording, message: "No dictation session is running.")
    }
    await self.main.endSession(trigger: .uiButton)

    switch self.main.state {
    case .completed(let item):
      let text = item.postProcessedTranscription?.isEmpty == false
        ? item.postProcessedTranscription ?? ""
        : item.rawTranscription ?? ""
      return AutomationResult(
        text: text,
        model: item.modelUsages.first?.modelIdentifier ?? item.modelsUsed.first,
        durationSeconds: item.recordingDuration,
        sessionActive: false
      )
    case .failed(let message):
      throw AutomationError(code: .transcriptionFailed, message: message)
    default:
      // Delivery can still be in flight; the transcript is already in history.
      return AutomationResult(
        text: self.history.items.first?.rawTranscription ?? "",
        sessionActive: self.main.activeSession != nil
      )
    }
  }
}
#endif
