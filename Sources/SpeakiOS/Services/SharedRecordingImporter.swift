#if os(iOS)
import Foundation
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

        let settings = AppSettings.shared
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

        var imported = 0
        for item in pending {
            do {
                try await transcribe(item, from: inbox, model: model, settings: settings)
                imported += 1
            } catch {
                logger.error(
                    """
                    Shared recording \(item.id.uuidString, privacy: .public) failed: \
                    \(error.localizedDescription, privacy: .public)
                    """
                )
                // Drop our copy rather than retry it on every foreground for
                // ever. The user still has the original and can share it again.
                inbox.remove(item)
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
        guard iOSHistoryManager.shared.recordTranscription(
            text: result.text,
            model: model,
            duration: result.duration
        ) != nil else {
            // A file that produced no words is not a success; saying
            // "transcribed" here is exactly the kind of claim #945 and #952
            // were about.
            throw ImportFailure.noSpeech
        }
        inbox.remove(item)
    }

    /// Clears the reported outcome once the app has shown it.
    public func acknowledgeOutcome() { lastOutcome = nil }

    enum ImportFailure: LocalizedError {
        case noSpeech

        var errorDescription: String? {
            "No speech was found in the recording."
        }
    }
}
#endif
