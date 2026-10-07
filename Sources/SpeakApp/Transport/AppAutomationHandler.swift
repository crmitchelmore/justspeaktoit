#if os(macOS)
import Foundation
import SpeakCore

/// Bridges automation commands onto the same managers the UI drives.
///
/// Deliberately thin: it maps app types onto the wire types and nothing else.
/// Option rejection, file-argument validation and error mapping are the shared
/// `AutomationCommandDispatcher` policy, so the Windows app answers the same
/// requests the same way. Dictation start/stop and file transcription reuse the
/// existing session and provider pipelines so an automation session behaves
/// exactly like a hotkey session.
@MainActor
final class AppAutomationHandler: AutomationCommandHandling, AutomationCommandHost {
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
        await AutomationCommandDispatcher.response(to: request, host: self)
    }

    // MARK: - AutomationCommandHost

    func automationStatus() async -> AutomationResult {
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
    func automationHistory(limit: Int) async -> [AutomationHistoryEntry] {
        await self.history.waitUntilLoaded()
        return self.history.allItems.prefix(limit).map { item in
            let text = Self.transcript(of: item)
            return AutomationHistoryEntry(
                id: item.id.uuidString,
                text: text,
                createdAt: item.createdAt,
                model: item.modelUsages.first?.modelIdentifier ?? item.modelsUsed.first,
                durationSeconds: item.recordingDuration,
                wordCount: AutomationHistoryEntry.wordCount(of: text)
            )
        }
    }

    /// The dispatcher has already checked the file exists and is within the cap.
    func automationTranscribeFile(at url: URL) async throws -> AutomationResult {
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

    func automationStartDictation() async throws -> AutomationResult {
        guard self.main.activeSession == nil, !self.main.isEndingSession else {
            throw AutomationError.dictationAlreadyRunning
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

    func automationStopDictation() async throws -> AutomationResult {
        guard let session = self.main.activeSession else {
            throw AutomationError.noDictationRunning
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
