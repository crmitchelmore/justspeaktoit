#if os(iOS)
import Foundation
import os
import SpeakCore

/// Transcribes the recordings the Share extension left in the App Group inbox
/// (issue #1020).
///
/// The extension takes the copy — it is the only process that can, while the
/// security-scoped URL is alive — and the app does the work, because the app is
/// the process that has the keys, the batch client and the History store, and
/// is not on an extension's memory budget.
///
/// **The user's recording is never touched.** Everything this class opens,
/// writes or deletes is inside our own App Group container: the copy the
/// extension made and its manifest. The original stays wherever the user keeps
/// it, unchanged, whatever happens here.
@MainActor
public final class SharedRecordingImporter: ObservableObject {
    /// What the last drain did, for the app to report. Never optimistic: a
    /// failure is reported as a failure, naming the file and the reason.
    public enum Outcome: Equatable {
        case imported(count: Int)
        case failed(filename: String, message: String)

        public var message: String {
            switch self {
            case .imported(let count):
                return count == 1
                    ? "Transcribed 1 shared recording. It is in History."
                    : "Transcribed \(count) shared recordings. They are in History."
            case .failed(let filename, let message):
                return "\"\(filename)\" could not be transcribed. \(message) "
                    + "Your recording was not changed."
            }
        }
    }

    public static let shared = SharedRecordingImporter()

    @Published public private(set) var isImporting = false
    @Published public private(set) var lastOutcome: Outcome?

    private let inbox: SharedRecordingInbox?
    /// Tests inject a store whose Keychain access they control.
    var credentialSettings: AppSettings?
    private let logger = SpeakLogger.logger(category: "SharedRecordingImporter")

    init(inbox: SharedRecordingInbox? = SharedRecordingInbox.shared()) {
        self.inbox = inbox
    }

    /// How many recordings are waiting. Cheap enough to call on every
    /// foreground.
    public var pendingCount: Int { inbox?.pending().count ?? 0 }

    /// Transcribes everything waiting, oldest first.
    ///
    /// Single-flight: a second foreground while the first drain is still
    /// uploading must not start the same file twice.
    public func drain() async {
        guard let inbox, !isImporting else { return }
        let pending = inbox.pending()
        guard !pending.isEmpty else { return }

        isImporting = true
        defer { isImporting = false }

        let settings = credentialSettings ?? AppSettings.shared
        await settings.ensureKeysLoaded()
        let model = settings.batchTranscriptionModel
        guard AppSettings.supportedBatchModels.contains(where: { $0.id == model }) else {
            // Every waiting item would fail the same way, so say it once and
            // leave them in the inbox: the user can fix the model in Settings
            // and the next foreground picks them up.
            lastOutcome = .failed(
                filename: pending[0].originalFilename,
                message: AutomationIntentError.unsupportedBatchModel(model).localizedDescription
            )
            return
        }
        do {
            try settings.requireAvailableCredentials(for: model, purpose: .batchTranscription)
        } catch {
            // Keychain access has not recovered yet (issue #930). An empty key
            // is not a terminal failure, so submitting it would spend one of
            // each item's attempts and eventually delete the staged audio.
            // Leave every item and its attempt count untouched instead.
            lastOutcome = .failed(
                filename: pending[0].originalFilename,
                message: error.localizedDescription
            )
            return
        }

        var imported = 0
        for item in pending {
            do {
                try await transcribe(item, from: inbox, model: model, settings: settings)
                imported += 1
            } catch {
                // Classification only, never the provider's response body:
                // the batch client can put an HTTP error payload in
                // `localizedDescription`, and that must not become public
                // device-log data. The user still sees the full message in the
                // in-app outcome below.
                logger.error(
                    """
                    Shared recording \(item.id.uuidString, privacy: .public) failed \
                    (\(Self.failureClassification(error), privacy: .public)): \
                    \(error.localizedDescription, privacy: .private)
                    """
                )
                Self.retire(item, after: error, from: inbox, logger: logger)
                lastOutcome = .failed(
                    filename: item.originalFilename,
                    message: error.localizedDescription
                )
                return
            }
        }
        if imported > 0 {
            lastOutcome = .imported(count: imported)
        }
    }

    /// Transcribes one staged recording and clears it. Throws rather than
    /// reporting, so the caller decides what a failure means for the rest of
    /// the queue.
    private func transcribe(
        _ item: SharedRecordingInboxItem,
        from inbox: SharedRecordingInbox,
        model: String,
        settings: AppSettings
    ) async throws {
        let audioURL = inbox.stagedURL(id: item.id, fileExtension: item.fileExtension)
        let result = try await IOSBatchTranscriber.transcribeFile(
            at: audioURL,
            model: model,
            apiKey: settings.batchAPIKey,
            language: settings.preferredModelLanguage,
            keywords: MetaMuseVoiceTranscribe.keywords(from: settings.transcriptionKeywords)
        )
        guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // A file that produced no words is not a success; saying
            // "transcribed" here is exactly the kind of claim #945 and #952
            // were about.
            throw ImportFailure.noSpeech
        }
        // The History entry carries the inbox item's own id, and the write is
        // only acknowledged when it reached disk.
        //
        // `recordTranscription` mints a fresh id and returns the item whether
        // or not the save succeeded, so acknowledging on a non-nil result
        // deleted the only staged copy of the user's audio on a persistence
        // failure — and a crash between a successful write and the delete made
        // the replay add a second entry with a different id. Upserting by a
        // stable id is idempotent: a replay updates the same row.
        guard iOSHistoryManager.shared.upsertReportingDurability(
            iOSHistoryItem(
                id: item.id,
                transcription: result.text,
                model: model,
                duration: result.duration,
                wordCount: result.text.split(whereSeparator: \.isWhitespace).count
            )
        ) else {
            throw ImportFailure.notSaved
        }
        // Only now: the recording is durably in History, so dropping our copy
        // cannot lose it.
        inbox.remove(item)
    }

    /// Decides what a failure means for the staged copy.
    ///
    /// A terminal failure — no speech in the file, a file this app will never
    /// accept, a model it cannot run — will fail the same way for ever, so the
    /// copy goes. Anything else (no network, a provider outage, a credential
    /// not loaded yet) is exactly what the durable hand-off exists for, so the
    /// item stays for the next foreground until it has used its attempts.
    private static func retire(
        _ item: SharedRecordingInboxItem,
        after error: Error,
        from inbox: SharedRecordingInbox,
        logger: os.Logger
    ) {
        guard !isTerminal(error) else {
            inbox.remove(item)
            return
        }
        let updated = inbox.registerAttempt(item)
        guard updated.attemptCount >= SharedRecordingInbox.maximumAttempts else {
            logger.info(
                """
                Shared recording \(item.id.uuidString, privacy: .public) kept for retry \
                (attempt \(updated.attemptCount, privacy: .public) of \
                \(SharedRecordingInbox.maximumAttempts, privacy: .public))
                """
            )
            return
        }
        inbox.remove(item)
    }

    private static func isTerminal(_ error: Error) -> Bool {
        if error is SharedAudioImportRejection { return true }
        if let failure = error as? ImportFailure { return failure == .noSpeech }
        if case AutomationIntentError.unsupportedBatchModel = error { return true }
        return false
    }

    /// A safe, non-identifying name for the log. Never the provider's own
    /// message, which can carry an HTTP response body.
    private static func failureClassification(_ error: Error) -> String {
        if let rejection = error as? SharedAudioImportRejection {
            return "rejected/\(String(describing: rejection).prefix(while: { $0 != "(" }))"
        }
        if let failure = error as? ImportFailure { return "import/\(failure)" }
        if let urlError = error as? URLError { return "network/\(urlError.code.rawValue)" }
        return "provider/\(String(describing: type(of: error)))"
    }

    /// Clears the reported outcome once the app has shown it.
    public func acknowledgeOutcome() { lastOutcome = nil }

    enum ImportFailure: String, LocalizedError, Equatable {
        case noSpeech
        case notSaved

        var errorDescription: String? {
            switch self {
            case .noSpeech:
                return "No speech was found in the recording."
            case .notSaved:
                return "The transcript could not be saved to History, so your recording was kept "
                    + "for another try."
            }
        }
    }
}
#endif
