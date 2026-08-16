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
            try Self.rejectUnappliedOptions(in: request)
            switch request.command {
            case .status:
                return .success(id: request.id, command: request.command, result: self.status())
            case .history:
                return .success(
                    id: request.id,
                    command: request.command,
                    result: AutomationResult(entries: await self.historyEntries(limit: request.resolvedLimit))
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

    /// Fails loudly for wire fields this build cannot honour.
    ///
    /// `provider` and `profile` are part of the schema so a later app version can
    /// apply them without a breaking change, but accepting them silently would
    /// report success for an override that never took effect.
    private static func rejectUnappliedOptions(in request: AutomationRequest) throws {
        if request.provider != nil {
            throw AutomationError(
                code: .invalidArgument,
                message: "This app version cannot override the transcription provider per request. "
                    + "Change the provider in Settings."
            )
        }
        if request.profile != nil {
            throw AutomationError(
                code: .invalidArgument,
                message: "This app version cannot select a dictation profile per request. "
                    + "Choose the profile in the app."
            )
        }
    }

    private func status() -> AutomationResult {
        AutomationResult(
            sessionActive: self.main.activeSession != nil,
            appVersion: self.appVersion
        )
    }

    /// Reads the whole persisted history, not the loaded page.
    ///
    /// `items` is the paged view the History window scrolls through (50 entries),
    /// while the wire contract advertises up to `AutomationLimits.maxHistoryLimit`,
    /// so paging must not silently truncate an automation reply. Waiting for the
    /// initial load also stops a request made during launch from reporting an
    /// empty history for a user who has one.
    private func historyEntries(limit: Int) async -> [AutomationHistoryEntry] {
        await self.history.waitUntilLoaded()
        return self.history.allItems.prefix(limit).map { item in
            let text = Self.transcript(of: item)
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
        guard self.main.activeSession == nil, !self.main.isEndingSession else {
            throw AutomationError(
                code: .alreadyRecording,
                message: "A dictation session is already running. Stop it before starting another."
            )
        }
        // Await the real session boundary rather than polling a detached UI task.
        // Permission and provider setup can legitimately exceed five seconds; the
        // server's request deadline reports that delay while the idempotent command
        // continues and can be collected by retrying the same request id.
        let outcome = await self.main.startSession(trigger: .automation)
        guard outcome == .started, self.main.activeSession != nil else {
            throw AutomationError(
                code: .transcriptionFailed,
                message: Self.failureMessage(from: self.main.state) ?? "Dictation could not be started."
            )
        }
        return AutomationResult(sessionActive: true)
    }

    private static func failureMessage(from state: MainManager.State) -> String? {
        guard case .failed(let message) = state else { return nil }
        return message
    }

    private func stopDictation() async throws -> AutomationResult {
        guard let session = self.main.activeSession else {
            throw AutomationError(code: .notRecording, message: "No dictation session is running.")
        }
        let sessionID = session.id
        await self.main.endSession(trigger: .automation)

        switch self.main.state {
        case .completed(let item):
            return AutomationResult(
                text: Self.transcript(of: item),
                model: item.modelUsages.first?.modelIdentifier ?? item.modelsUsed.first,
                durationSeconds: item.recordingDuration,
                sessionActive: false
            )
        case .failed(let message):
            throw AutomationError(code: .transcriptionFailed, message: message)
        default:
            // Delivery can still be in flight. Only this session's own item counts —
            // the newest history entry may belong to an earlier session.
            let item = self.history.allItems.first { $0.id == sessionID }
            return AutomationResult(
                text: item.map(Self.transcript(of:)) ?? "",
                model: item?.modelUsages.first?.modelIdentifier ?? item?.modelsUsed.first,
                durationSeconds: item?.recordingDuration,
                sessionActive: self.main.activeSession != nil
            )
        }
    }

    /// Post-processed text when there is any, matching what History shows.
    private static func transcript(of item: HistoryItem) -> String {
        item.postProcessedTranscription?.isEmpty == false
            ? item.postProcessedTranscription ?? ""
            : item.rawTranscription ?? ""
    }
}
#endif
